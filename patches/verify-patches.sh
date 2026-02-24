#!/bin/bash
#===============================================================================
# Verify all patches are applied correctly.
# Can be run standalone or called from install.sh
#===============================================================================

set -o pipefail

R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  NC='\033[0m'

PASS=0
FAIL=0

check() {
  local label="$1"
  shift
  if "$@" 2>/dev/null; then
    echo -e "  ${G}✓${NC} $label"
    PASS=$((PASS + 1))
  else
    echo -e "  ${R}✗${NC} $label"
    FAIL=$((FAIL + 1))
  fi
}

MEM0_DIR="$HOME/.openclaw/extensions/openclaw-mem0/node_modules/mem0ai/dist/oss"

echo ""
echo "Verifying Mem0 SDK patches..."

if [ ! -d "$MEM0_DIR" ]; then
  echo -e "  ${Y}⚠${NC} Mem0 dist directory not found: $MEM0_DIR"
  echo "  Skipping mem0 patch verification."
else
  for ext in mjs js; do
    FILE="$MEM0_DIR/index.$ext"
    if [ ! -f "$FILE" ]; then
      echo -e "  ${Y}⚠${NC} index.$ext not found"
      continue
    fi

    echo "  index.$ext:"

    # Patch 1: JSON in entity extraction
    check "    Patch 1: JSON instruction in entity extraction" \
      grep -q 'Return your response as json' "$FILE"

    # Patch 2: JSON in delete relations
    check "    Patch 2: JSON instruction in delete relations" \
      grep -q 'relationship to be deleted. Return your response as json' "$FILE"

    # Patch 3: conditional response_format
    check "    Patch 3: conditional response_format" \
      grep -q '!tools && responseFormat' "$FILE"

    # Patch 4a: baseURL in OpenAIEmbedder constructor
    check "    Patch 4a: OpenAIEmbedder accepts baseURL" \
      grep -q 'config.baseURL && { baseURL: config.baseURL }' "$FILE"

    # Patch 4b: dimensions in embed()
    check "    Patch 4b: embed() passes dimensions" \
      grep -q 'this.embeddingDims && { dimensions: this.embeddingDims }' "$FILE"

    # Patch 5: mergeConfig preserves baseURL
    check "    Patch 5: mergeConfig preserves baseURL" \
      grep -q 'baseURL: userConf' "$FILE"

    echo ""
  done
fi

echo "Verifying OpenClaw BUSINESS.md patch..."

OPENCLAW_BIN="$(which openclaw 2>/dev/null || echo '')"
if [ -n "$OPENCLAW_BIN" ]; then
  # Resolve symlink to find real install
  OPENCLAW_REAL="$(readlink -f "$OPENCLAW_BIN" 2>/dev/null || realpath "$OPENCLAW_BIN" 2>/dev/null || echo "$OPENCLAW_BIN")"
  OPENCLAW_DIR="$(dirname "$OPENCLAW_REAL")/../lib/node_modules/openclaw/dist"
  if [ ! -d "$OPENCLAW_DIR" ]; then
    OPENCLAW_DIR="$(dirname "$OPENCLAW_BIN")/../lib/node_modules/openclaw/dist"
  fi

  if [ -d "$OPENCLAW_DIR" ]; then
    FOUND=0
    TOTAL=0
    for file in "$OPENCLAW_DIR"/agent-scope-*.js; do
      [ -f "$file" ] || continue
      TOTAL=$((TOTAL + 1))
      if grep -q 'BUSINESS.md' "$file" 2>/dev/null; then
        FOUND=$((FOUND + 1))
      fi
    done
    if [ $FOUND -gt 0 ]; then
      echo -e "  ${G}✓${NC} BUSINESS.md injection ($FOUND of $TOTAL agent-scope files patched)"
      PASS=$((PASS + 1))
    else
      echo -e "  ${R}✗${NC} BUSINESS.md injection (0 of $TOTAL files patched)"
      FAIL=$((FAIL + 1))
    fi
  else
    echo -e "  ${Y}⚠${NC} OpenClaw dist directory not found"
  fi
else
  echo -e "  ${Y}⚠${NC} OpenClaw not in PATH"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ $FAIL -eq 0 ] && exit 0 || exit 1

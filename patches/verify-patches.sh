#!/bin/bash
#===============================================================================
# Verify all patches are applied correctly.
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

# Check ESM build
check "index.mjs: conditional response_format" \
  grep -q '!tools && responseFormat' "$MEM0_DIR/index.mjs"

check "index.mjs: embedder retry logic" \
  grep -q 'attempt < 3' "$MEM0_DIR/index.mjs"

check "index.mjs: JSON instruction in entity extraction" \
  grep -q 'Return your response as json' "$MEM0_DIR/index.mjs"

# Check CJS build
check "index.js: conditional response_format" \
  grep -q '!tools && responseFormat' "$MEM0_DIR/index.js"

check "index.js: embedder retry logic" \
  grep -q 'attempt < 3' "$MEM0_DIR/index.js"

check "index.js: JSON instruction in entity extraction" \
  grep -q 'Return your response as json' "$MEM0_DIR/index.js"

# Check baseURL preservation
check "index.mjs: baseURL preserved in mergeConfig" \
  grep -q 'baseURL.*userConf' "$MEM0_DIR/index.mjs"

check "index.js: baseURL preserved in mergeConfig" \
  grep -q 'baseURL.*userConf' "$MEM0_DIR/index.js"

echo ""
echo "Verifying OpenClaw BUSINESS.md patch..."

OPENCLAW_BIN="$(which openclaw 2>/dev/null || echo '')"
if [ -n "$OPENCLAW_BIN" ]; then
  OPENCLAW_DIR="$(dirname "$OPENCLAW_BIN")/../lib/node_modules/openclaw/dist"
  if [ -d "$OPENCLAW_DIR" ]; then
    FOUND=0
    for file in "$OPENCLAW_DIR"/agent-scope-*.js; do
      [ -f "$file" ] || continue
      if grep -q 'BUSINESS.md' "$file" 2>/dev/null; then
        FOUND=$((FOUND + 1))
      fi
    done
    if [ $FOUND -gt 0 ]; then
      echo -e "  ${G}✓${NC} BUSINESS.md injection ($FOUND files patched)"
      PASS=$((PASS + 1))
    else
      echo -e "  ${R}✗${NC} BUSINESS.md injection (0 files patched)"
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

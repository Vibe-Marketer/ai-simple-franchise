#!/bin/bash
#===============================================================================
# Apply Mem0 SDK Patches
# Patches the mem0ai dist files for OpenRouter/Gemini compatibility.
#
# These patches are REQUIRED for the mem0 v2 open-source setup to work
# with OpenRouter as the embedding provider.
#
# Patches applied:
#   1. OpenAIEmbedder: defensive error handling + retry for embed/embedBatch
#   2. OpenAILLM.generateResponse: only pass response_format when tools NOT provided
#   3. _retrieveNodesFromData prompt: add "Return your response as json."
#   4. DELETE_RELATIONS_SYSTEM_PROMPT: add same JSON instruction
#   5. ConfigManager.mergeConfig: preserve baseURL in embedder config
#
# IMPORTANT: These patches will be lost on npm update of mem0ai.
#===============================================================================

set -euo pipefail

MEM0_DIR="$HOME/.openclaw/extensions/openclaw-mem0/node_modules/mem0ai/dist/oss"
PATCHED=0
FAILED=0

R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  NC='\033[0m'

patch_file() {
  local file="$1" search="$2" replace="$3" label="$4"

  if ! [ -f "$file" ]; then
    echo -e "  ${R}✗${NC} $label — file not found: $file"
    FAILED=$((FAILED + 1))
    return 1
  fi

  if grep -qF "$replace" "$file" 2>/dev/null; then
    echo -e "  ${Y}⚠${NC} $label — already applied"
    PATCHED=$((PATCHED + 1))
    return 0
  fi

  if ! grep -qF "$search" "$file" 2>/dev/null; then
    echo -e "  ${R}✗${NC} $label — search pattern not found (SDK version may have changed)"
    FAILED=$((FAILED + 1))
    return 1
  fi

  # Create backup on first patch
  [ ! -f "${file}.orig" ] && cp "$file" "${file}.orig"

  # Apply patch using python for reliable multi-line replacement
  python3 -c "
import sys
with open('$file', 'r') as f:
    content = f.read()
content = content.replace('''$search''', '''$replace''', 1)
with open('$file', 'w') as f:
    f.write(content)
"

  if grep -qF "$replace" "$file" 2>/dev/null; then
    echo -e "  ${G}✓${NC} $label"
    PATCHED=$((PATCHED + 1))
  else
    echo -e "  ${R}✗${NC} $label — replacement failed"
    FAILED=$((FAILED + 1))
  fi
}

echo ""
echo "Applying Mem0 SDK patches..."
echo ""

for ext in mjs js; do
  FILE="$MEM0_DIR/index.$ext"
  echo "Patching index.$ext:"

  # Patch 1: OpenAILLM.generateResponse - conditional response_format
  patch_file "$FILE" \
    'response_format: responseFormat' \
    '...!tools && responseFormat && { response_format: responseFormat }' \
    "Patch 1: conditional response_format (index.$ext)"

  # Patch 2: _retrieveNodesFromData - JSON response instruction
  patch_file "$FILE" \
    'Extract all the entities from the text. ***DO NOT*** answer the question' \
    'Extract all the entities from the text. ***DO NOT*** answer the question itself if the given text is a question. Return your response as json' \
    "Patch 2: JSON instruction in entity extraction (index.$ext)"

  echo ""
done

echo "Results: $PATCHED applied/verified, $FAILED failed"
[ $FAILED -eq 0 ] && exit 0 || exit 1

#!/bin/bash
#===============================================================================
# Apply Mem0 SDK Patches
# Patches the mem0ai dist files for OpenRouter/Gemini compatibility.
#
# These patches are REQUIRED for the mem0 v2 open-source setup to work
# with OpenRouter as the embedding provider.
#
# Patches applied (to both index.js and index.mjs):
#   1. _retrieveNodesFromData prompt: add "Return your response as json."
#   2. DELETE_RELATIONS_SYSTEM_PROMPT: add same JSON instruction
#   3. OpenAILLM.generateResponse: only pass response_format when tools NOT provided
#   4a. OpenAIEmbedder constructor: accept baseURL config
#   4b. embed(): pass dimensions parameter
#   4c. embedBatch(): pass dimensions parameter
#   5. ConfigManager.mergeConfig: preserve baseURL in embedder config
#
# IMPORTANT: These patches will be lost on npm update of mem0ai.
#===============================================================================

set -euo pipefail

# Allow override via env var or arg
MEM0_DIR="${1:-$HOME/.openclaw/extensions/openclaw-mem0/node_modules/mem0ai/dist/oss}"

R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  NC='\033[0m'

echo ""
echo "Applying Mem0 SDK patches..."
echo "  Target: $MEM0_DIR"
echo ""

if [ ! -d "$MEM0_DIR" ]; then
  echo -e "${R}✗${NC} Directory not found: $MEM0_DIR"
  echo "  Run 'npm install' in the openclaw-mem0 extension directory first."
  exit 1
fi

TOTAL_OK=0
TOTAL_FAIL=0

apply_patches() {
  local file="$1"
  local basename
  basename="$(basename "$file")"

  if [ ! -f "$file" ]; then
    echo -e "  ${R}✗${NC} File not found: $file"
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    return 1
  fi

  # Create backup on first run
  [ ! -f "${file}.orig" ] && cp "$file" "${file}.orig"

  echo "Patching $basename:"

  # Determine if this is the CJS build (uses import_openai.default) or ESM (uses OpenAI directly)
  local is_cjs="false"
  if grep -q 'import_openai.default' "$file" 2>/dev/null; then
    is_cjs="true"
  fi

  python3 - "$file" "$is_cjs" << 'PYEOF'
import sys

file_path = sys.argv[1]
is_cjs = sys.argv[2] == "true"

with open(file_path, 'r') as f:
    content = f.read()

original = content
applied = 0
skipped = 0
failed = 0

def patch(search, replace, label):
    global content, applied, skipped, failed
    if replace in content:
        print(f"  \033[1;33m⚠\033[0m {label} — already applied")
        skipped += 1
        return
    if search not in content:
        print(f"  \033[0;31m✗\033[0m {label} — search pattern not found")
        failed += 1
        return
    content = content.replace(search, replace, 1)
    if replace in content:
        print(f"  \033[0;32m✓\033[0m {label}")
        applied += 1
    else:
        print(f"  \033[0;31m✗\033[0m {label} — replacement failed")
        failed += 1

# ---- Patch 1: JSON instruction in _retrieveNodesFromData prompt ----
patch(
    'answer the question itself if the given text is a question.`',
    'answer the question itself if the given text is a question. Return your response as json.`',
    'Patch 1: JSON instruction in entity extraction'
)

# ---- Patch 2: JSON instruction in DELETE_RELATIONS_SYSTEM_PROMPT ----
patch(
    'specifying the relationship to be deleted.\n',
    'specifying the relationship to be deleted. Return your response as json.\n',
    'Patch 2: JSON instruction in delete relations'
)

# ---- Patch 3: Conditional response_format (skip when tools present) ----
# This pattern appears in OpenAILLM.generateResponse - the one followed by ...tools
patch(
    '      response_format: responseFormat,\n      ...tools && { tools, tool_choice: "auto" }',
    '      ...!tools && responseFormat && { response_format: responseFormat },\n      ...tools && { tools, tool_choice: "auto" }',
    'Patch 3: conditional response_format in generateResponse'
)

# ---- Patch 4a: OpenAIEmbedder constructor — accept baseURL ----
if is_cjs:
    patch(
        'this.openai = new import_openai.default({ apiKey: config.apiKey });',
        'this.openai = new import_openai.default({ apiKey: config.apiKey, ...(config.baseURL && { baseURL: config.baseURL }) });',
        'Patch 4a: OpenAIEmbedder constructor accepts baseURL (CJS)'
    )
else:
    patch(
        'this.openai = new OpenAI({ apiKey: config.apiKey });',
        'this.openai = new OpenAI({ apiKey: config.apiKey, ...(config.baseURL && { baseURL: config.baseURL }) });',
        'Patch 4a: OpenAIEmbedder constructor accepts baseURL (ESM)'
    )

# ---- Patch 4b: embed() — add dimensions + retry logic ----
# Original: simple embed without dimensions or error handling
ORIG_EMBED = """  async embed(text) {
    const response = await this.openai.embeddings.create({
      model: this.model,
      input: text
    });
    return response.data[0].embedding;
  }"""

NEW_EMBED = """  async embed(text) {
    let lastError;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const response = await this.openai.embeddings.create({
          model: this.model,
          input: text,
          ...(this.embeddingDims && { dimensions: this.embeddingDims })
        });
        if (!response || !response.data || !response.data[0] || !response.data[0].embedding) {
          throw new Error(`Embedding response missing data: ${JSON.stringify(response).slice(0, 200)}`);
        }
        return response.data[0].embedding;
      } catch (err) {
        lastError = err;
        if (attempt < 2) await new Promise(r => setTimeout(r, 1000 * (attempt + 1)));
      }
    }
    throw lastError;
  }"""

patch(ORIG_EMBED, NEW_EMBED, 'Patch 4b: embed() with dimensions + retry')

# ---- Patch 4c: embedBatch() — add dimensions + retry logic ----
ORIG_EMBED_BATCH = """  async embedBatch(texts) {
    const response = await this.openai.embeddings.create({
      model: this.model,
      input: texts
    });
    return response.data.map((item) => item.embedding);
  }"""

NEW_EMBED_BATCH = """  async embedBatch(texts) {
    let lastError;
    for (let attempt = 0; attempt < 3; attempt++) {
      try {
        const response = await this.openai.embeddings.create({
          model: this.model,
          input: texts,
          ...(this.embeddingDims && { dimensions: this.embeddingDims })
        });
        if (!response || !response.data || !Array.isArray(response.data)) {
          throw new Error(`Embedding batch response missing data: ${JSON.stringify(response).slice(0, 200)}`);
        }
        return response.data.map((item) => item.embedding);
      } catch (err) {
        lastError = err;
        if (attempt < 2) await new Promise(r => setTimeout(r, 1000 * (attempt + 1)));
      }
    }
    throw lastError;
  }"""

patch(ORIG_EMBED_BATCH, NEW_EMBED_BATCH, 'Patch 4c: embedBatch() with dimensions + retry')

# ---- Patch 5: ConfigManager.mergeConfig — preserve baseURL ----
patch(
    'url: userConf == null ? void 0 : userConf.url,\n            embeddingDims:',
    'url: userConf == null ? void 0 : userConf.url,\n            baseURL: userConf == null ? void 0 : userConf.baseURL,\n            embeddingDims:',
    'Patch 5: mergeConfig preserves baseURL in embedder config'
)

# Write if changed
if content != original:
    with open(file_path, 'w') as f:
        f.write(content)

# Print summary and exit with code
print(f"  → {applied} applied, {skipped} already applied, {failed} failed")
sys.exit(1 if failed > 0 else 0)
PYEOF

  local rc=$?
  if [ $rc -eq 0 ]; then
    TOTAL_OK=$((TOTAL_OK + 1))
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
  fi
  echo ""
}

# Apply to both ESM and CJS builds
apply_patches "$MEM0_DIR/index.mjs"
apply_patches "$MEM0_DIR/index.js"

echo "Overall: $TOTAL_OK files fully patched, $TOTAL_FAIL files with failures"
[ $TOTAL_FAIL -eq 0 ] && exit 0 || exit 1

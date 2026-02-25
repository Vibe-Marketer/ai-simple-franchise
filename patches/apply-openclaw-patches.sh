#!/bin/bash
#===============================================================================
# Apply OpenClaw BUSINESS.md Injection Patch
#
# Adds BUSINESS.md to the list of workspace files that get injected every turn.
# This patch modifies OpenClaw's compiled dist files.
#
# The patch adds a BUSINESS.md entry to the entries array in
# loadWorkspaceBootstrapFiles(), after the existing BOOTSTRAP.md entry.
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
SKIPPED=0
FAILED=0

for file in "$OPENCLAW_DIR"/agent-scope-*.js; do
  [ -f "$file" ] || continue
  [[ "$file" == *.orig ]] && continue
  BASENAME="$(basename "$file")"

  # Check if BUSINESS.md entry already exists in the entries array (correct patch)
  if grep -q '"BUSINESS.md"' "$file" 2>/dev/null; then
    # Verify it's correctly patched (in entries array, not in const declaration)
    if python3 -c "
import sys
with open('$file', 'r') as f:
    content = f.read()
# Check for BROKEN const declaration pattern
if '\"BOOTSTRAP.md\",\"BUSINESS.md\"' in content:
    sys.exit(1)  # Broken
# Check for correct entries array pattern
if 'name: \"BUSINESS.md\"' in content:
    sys.exit(0)  # Correct
sys.exit(1)  # Unknown state
" 2>/dev/null; then
      echo -e "  ${Y}⚠${NC} $BASENAME — already correctly patched"
      PATCHED=$((PATCHED + 1))
      continue
    else
      echo -e "  ${R}!${NC} $BASENAME — has broken BUSINESS.md patch, will restore and re-patch"
      # Restore from .orig if available
      if [ -f "${file}.orig" ]; then
        cp "${file}.orig" "$file"
        echo -e "      Restored from .orig backup"
      else
        echo -e "  ${R}✗${NC} $BASENAME — broken patch but no .orig backup to restore from"
        FAILED=$((FAILED + 1))
        continue
      fi
    fi
  fi

  # Check if file has the entries array with BOOTSTRAP entry
  if ! grep -q 'name: DEFAULT_BOOTSTRAP_FILENAME' "$file" 2>/dev/null; then
    echo -e "  ${Y}⚠${NC} $BASENAME — no entries array with BOOTSTRAP (skipping)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Backup
  [ ! -f "${file}.orig" ] && cp "$file" "${file}.orig"

  # Apply patch: add BUSINESS.md entry after the BOOTSTRAP entry in the entries array
  # We look for the pattern:
  #   { name: DEFAULT_BOOTSTRAP_FILENAME, filePath: path.join(resolvedDir, DEFAULT_BOOTSTRAP_FILENAME) }
  #   ];
  # And insert a new entry between them.
  if python3 -c "
import re, sys

with open('$file', 'r') as f:
    content = f.read()

# Pattern: the BOOTSTRAP entry object followed by the closing of the entries array
# This handles both tab-indented and space-indented code
# The key is matching the BOOTSTRAP entry followed by \n\t]; or \n  ];
pattern = r'(name:\s*DEFAULT_BOOTSTRAP_FILENAME,\s*filePath:\s*path\.join\(resolvedDir,\s*DEFAULT_BOOTSTRAP_FILENAME\)\s*\})\s*(\n[ \t]*\];)'

replacement = r'''\1,
\t\t{
\t\t\tname: \"BUSINESS.md\",
\t\t\tfilePath: path.join(resolvedDir, \"BUSINESS.md\")
\t\t}\2'''

new_content, count = re.subn(pattern, replacement, content)

if count == 0:
    print('No match found for entries array pattern', file=sys.stderr)
    sys.exit(1)

with open('$file', 'w') as f:
    f.write(new_content)

print(f'Applied {count} replacement(s)')
" 2>&1; then
    if grep -q 'name: "BUSINESS.md"' "$file" 2>/dev/null; then
      echo -e "  ${G}✓${NC} $BASENAME — patched"
      PATCHED=$((PATCHED + 1))
    else
      echo -e "  ${R}✗${NC} $BASENAME — patch verification failed"
      FAILED=$((FAILED + 1))
    fi
  else
    echo -e "  ${R}✗${NC} $BASENAME — python patch failed"
    FAILED=$((FAILED + 1))
  fi
done

# Also check plugin-sdk subdirectory
PLUGIN_SDK="$OPENCLAW_DIR/plugin-sdk"
if [ -d "$PLUGIN_SDK" ]; then
  for file in "$PLUGIN_SDK"/agent-scope-*.js; do
    [ -f "$file" ] || continue
    [[ "$file" == *.orig ]] && continue
    BASENAME="plugin-sdk/$(basename "$file")"

    if grep -q 'name: "BUSINESS.md"' "$file" 2>/dev/null; then
      echo -e "  ${Y}⚠${NC} $BASENAME — already correctly patched"
      PATCHED=$((PATCHED + 1))
      continue
    fi

    if ! grep -q 'name: DEFAULT_BOOTSTRAP_FILENAME' "$file" 2>/dev/null; then
      echo -e "  ${Y}⚠${NC} $BASENAME — no entries array with BOOTSTRAP (skipping)"
      SKIPPED=$((SKIPPED + 1))
      continue
    fi

    [ ! -f "${file}.orig" ] && cp "$file" "${file}.orig"

    if python3 -c "
import re, sys

with open('$file', 'r') as f:
    content = f.read()

pattern = r'(name:\s*DEFAULT_BOOTSTRAP_FILENAME,\s*filePath:\s*path\.join\(resolvedDir,\s*DEFAULT_BOOTSTRAP_FILENAME\)\s*\})\s*(\n[ \t]*\];)'

replacement = r'''\1,
\t\t{
\t\t\tname: \"BUSINESS.md\",
\t\t\tfilePath: path.join(resolvedDir, \"BUSINESS.md\")
\t\t}\2'''

new_content, count = re.subn(pattern, replacement, content)

if count == 0:
    print('No match found for entries array pattern', file=sys.stderr)
    sys.exit(1)

with open('$file', 'w') as f:
    f.write(new_content)

print(f'Applied {count} replacement(s)')
" 2>&1; then
      if grep -q 'name: "BUSINESS.md"' "$file" 2>/dev/null; then
        echo -e "  ${G}✓${NC} $BASENAME — patched"
        PATCHED=$((PATCHED + 1))
      else
        echo -e "  ${R}✗${NC} $BASENAME — patch verification failed"
        FAILED=$((FAILED + 1))
      fi
    else
      echo -e "  ${R}✗${NC} $BASENAME — python patch failed"
      FAILED=$((FAILED + 1))
    fi
  done
fi

echo ""
echo "Results: $PATCHED patched/verified, $SKIPPED skipped, $FAILED failed"
[ $FAILED -eq 0 ] && exit 0 || exit 1

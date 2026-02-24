#!/bin/bash
#===============================================================================
# OpenClaw Franchise Update Checker
# Checks for available updates across the full franchise stack and optionally
# notifies via OpenClaw messaging.
#
# Usage:
#   ./update-check.sh [--notify PHONE] [--json] [--quiet]
#
# Exit codes:
#   0 — all components up to date
#   1 — updates available
#   2 — error during check
#===============================================================================

set -o pipefail

#-------------------------------------------------------------------------------
# Colors (matches franchise color scheme)
#-------------------------------------------------------------------------------
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  B='\033[0;34m'  C='\033[0;36m'  NC='\033[0m'

#-------------------------------------------------------------------------------
# Flags
#-------------------------------------------------------------------------------
NOTIFY_PHONE=""
OUTPUT_JSON=false
QUIET=false

while [ $# -gt 0 ]; do
  case "$1" in
    --notify)
      if [ -z "${2:-}" ]; then echo "Error: --notify requires a phone number"; exit 2; fi
      NOTIFY_PHONE="$2"; shift 2 ;;
    --json)
      OUTPUT_JSON=true; shift ;;
    --quiet)
      QUIET=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--notify PHONE] [--json] [--quiet]"
      echo ""
      echo "Options:"
      echo "  --notify PHONE   Send update notification via OpenClaw messaging"
      echo "  --json           Output results as JSON for programmatic use"
      echo "  --quiet          No output, just exit code (0=current, 1=updates)"
      echo "  --help, -h       Show this help message"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

#-------------------------------------------------------------------------------
# State
#-------------------------------------------------------------------------------
UPDATES=()          # Array of "component|current|available" entries
ERRORS=()           # Components that failed to check
CHECKED=0

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
semver_strip() {
  # Strip leading 'v' and any trailing whitespace
  echo "$1" | sed 's/^v//; s/[[:space:]]*$//'
}

versions_differ() {
  local a b
  a="$(semver_strip "$1")"
  b="$(semver_strip "$2")"
  [ "$a" != "$b" ]
}

#-------------------------------------------------------------------------------
# 1. OpenClaw CLI
#-------------------------------------------------------------------------------
check_openclaw() {
  local current latest
  current="$(openclaw --version 2>/dev/null)" || { ERRORS+=("openclaw-cli"); return; }
  current="$(semver_strip "$current")"
  latest="$(npm view openclaw version 2>/dev/null)" || { ERRORS+=("openclaw-cli-registry"); return; }
  latest="$(semver_strip "$latest")"
  CHECKED=$((CHECKED + 1))
  if versions_differ "$current" "$latest"; then
    UPDATES+=("OpenClaw CLI|$current|$latest")
  fi
}

#-------------------------------------------------------------------------------
# 2. Node.js (compare against latest LTS)
#-------------------------------------------------------------------------------
check_nodejs() {
  local current latest_lts
  current="$(node -v 2>/dev/null)" || { ERRORS+=("nodejs"); return; }
  current="$(semver_strip "$current")"

  # nodejs.org/dist/index.json is sorted newest-first; find the first LTS entry
  latest_lts="$(
    curl -sf --max-time 10 https://nodejs.org/dist/index.json \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
for entry in data:
    if entry.get('lts'):
        print(entry['version'])
        break
" 2>/dev/null
  )" || { ERRORS+=("nodejs-lts-fetch"); return; }
  latest_lts="$(semver_strip "$latest_lts")"

  CHECKED=$((CHECKED + 1))
  if [ -z "$latest_lts" ]; then
    ERRORS+=("nodejs-lts-parse")
    return
  fi
  if versions_differ "$current" "$latest_lts"; then
    UPDATES+=("Node.js LTS|$current|$latest_lts")
  fi
}

#-------------------------------------------------------------------------------
# 3. Franchise repo (git upstream changes)
#-------------------------------------------------------------------------------
check_franchise_repo() {
  local franchise_dir
  franchise_dir="$(cd "$(dirname "$0")/.." && pwd)"

  if [ ! -d "$franchise_dir/.git" ]; then
    # Not a git repo, skip silently
    return
  fi

  CHECKED=$((CHECKED + 1))

  local fetch_output
  fetch_output="$(git -C "$franchise_dir" fetch --dry-run 2>&1)" || {
    ERRORS+=("franchise-git-fetch")
    return
  }

  # If fetch --dry-run produces output, there are upstream changes
  if [ -n "$fetch_output" ]; then
    local behind
    behind="$(git -C "$franchise_dir" rev-list --count HEAD..@{u} 2>/dev/null || echo "?")"
    UPDATES+=("Franchise repo|current|${behind} commits behind")
  fi
}

#-------------------------------------------------------------------------------
# 4. mem0ai package
#-------------------------------------------------------------------------------
check_mem0() {
  local mem0_pkg="$HOME/.openclaw/extensions/openclaw-mem0/node_modules/mem0ai/package.json"

  if [ ! -f "$mem0_pkg" ]; then
    ERRORS+=("mem0ai-not-installed")
    return
  fi

  local current latest
  current="$(python3 -c "import json; print(json.load(open('$mem0_pkg'))['version'])" 2>/dev/null)" || {
    ERRORS+=("mem0ai-version-read")
    return
  }
  latest="$(npm view mem0ai version 2>/dev/null)" || {
    ERRORS+=("mem0ai-registry")
    return
  }
  latest="$(semver_strip "$latest")"

  CHECKED=$((CHECKED + 1))
  if versions_differ "$current" "$latest"; then
    UPDATES+=("mem0ai|$current|$latest")
  fi
}

#-------------------------------------------------------------------------------
# 5. Docker: neo4j:community image
#-------------------------------------------------------------------------------
check_neo4j_image() {
  # Ensure Docker is running
  docker info &>/dev/null || { ERRORS+=("docker-not-running"); return; }

  # Get locally installed neo4j image tag
  local local_digest remote_digest
  local_digest="$(docker inspect --format='{{index .RepoDigests 0}}' neo4j:community 2>/dev/null)" || {
    # Image might not exist locally at all
    ERRORS+=("neo4j-image-not-local")
    return
  }

  CHECKED=$((CHECKED + 1))

  # Pull the latest manifest without downloading layers to compare digests
  # Use docker manifest inspect if available, otherwise try a registry API call
  remote_digest="$(docker manifest inspect neo4j:community 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
# docker manifest inspect returns a manifest list or a single manifest
if 'manifests' in data:
    for m in data['manifests']:
        if m.get('platform',{}).get('architecture') == '$(uname -m | sed 's/x86_64/amd64/; s/arm64/arm64/')':
            print(m['digest'])
            break
elif 'config' in data:
    print(data.get('config',{}).get('digest',''))
" 2>/dev/null)" || remote_digest=""

  if [ -z "$remote_digest" ]; then
    # Fallback: compare created dates via Docker Hub API
    local local_created remote_tag remote_created
    local_created="$(docker inspect --format='{{.Created}}' neo4j:community 2>/dev/null)"

    # Query Docker Hub for the latest community tag's last_updated
    remote_created="$(
      curl -sf --max-time 10 "https://hub.docker.com/v2/repositories/library/neo4j/tags/community" \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('last_updated',''))" 2>/dev/null
    )" || remote_created=""

    if [ -n "$local_created" ] && [ -n "$remote_created" ]; then
      # Compare ISO timestamps (lexicographic comparison works for ISO 8601)
      local local_ts remote_ts
      local_ts="$(echo "$local_created" | cut -c1-19)"
      remote_ts="$(echo "$remote_created" | cut -c1-19)"
      if [[ "$remote_ts" > "$local_ts" ]]; then
        UPDATES+=("neo4j:community|local=$local_ts|remote=$remote_ts")
      fi
    fi
    return
  fi

  # Compare digests
  if [ -n "$remote_digest" ] && ! echo "$local_digest" | grep -q "$remote_digest"; then
    UPDATES+=("neo4j:community|local image|newer image available")
  fi
}

#-------------------------------------------------------------------------------
# Run all checks
#-------------------------------------------------------------------------------
check_openclaw
check_nodejs
check_franchise_repo
check_mem0
check_neo4j_image

#-------------------------------------------------------------------------------
# Determine exit code
#-------------------------------------------------------------------------------
HAS_UPDATES=0
if [ ${#UPDATES[@]} -gt 0 ]; then
  HAS_UPDATES=1
fi

#-------------------------------------------------------------------------------
# Output: --quiet mode
#-------------------------------------------------------------------------------
if $QUIET; then
  exit $HAS_UPDATES
fi

#-------------------------------------------------------------------------------
# Output: --json mode
#-------------------------------------------------------------------------------
if $OUTPUT_JSON; then
  # Build JSON manually to avoid jq dependency
  echo "{"
  echo "  \"has_updates\": $( [ $HAS_UPDATES -eq 1 ] && echo 'true' || echo 'false' ),"
  echo "  \"checked\": $CHECKED,"
  echo "  \"updates\": ["
  i=0
  for entry in "${UPDATES[@]+"${UPDATES[@]}"}"; do
    IFS='|' read -r component current available <<< "$entry"
    [ $i -gt 0 ] && echo ","
    printf '    {"component": "%s", "current": "%s", "available": "%s"}' \
      "$component" "$current" "$available"
    i=$((i + 1))
  done
  echo ""
  echo "  ],"
  echo "  \"errors\": ["
  i=0
  for err in "${ERRORS[@]+"${ERRORS[@]}"}"; do
    [ $i -gt 0 ] && echo ","
    printf '    "%s"' "$err"
    i=$((i + 1))
  done
  echo ""
  echo "  ],"
  echo "  \"timestamp\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
  echo "}"

  # Send notification if requested
  if [ -n "$NOTIFY_PHONE" ] && [ $HAS_UPDATES -eq 1 ]; then
    msg="Updates available:"
    for entry in "${UPDATES[@]}"; do
      IFS='|' read -r component current available <<< "$entry"
      msg="$msg $component ($current -> $available);"
    done
    openclaw message send "$NOTIFY_PHONE" "$msg" &>/dev/null || true
  fi

  exit $HAS_UPDATES
fi

#-------------------------------------------------------------------------------
# Output: normal (pretty) mode
#-------------------------------------------------------------------------------
if [ $HAS_UPDATES -eq 0 ] && [ ${#ERRORS[@]} -eq 0 ]; then
  # All clear — exit silently per spec
  exit 0
fi

echo ""
echo -e "${C}+--------------------------------------------------------------+${NC}"
echo -e "${C}|              OpenClaw Franchise Update Check                 |${NC}"
echo -e "${C}+--------------------------------------------------------------+${NC}"
echo ""

if [ $HAS_UPDATES -eq 1 ]; then
  echo -e "${Y}Updates available:${NC}"
  echo ""
  for entry in "${UPDATES[@]}"; do
    IFS='|' read -r component current available <<< "$entry"
    printf "  ${Y}*${NC} %-20s  ${R}%-14s${NC}  ->  ${G}%s${NC}\n" "$component" "$current" "$available"
  done
  echo ""
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
  echo -e "${R}Check errors:${NC}"
  for err in "${ERRORS[@]}"; do
    echo -e "  ${R}!${NC} $err"
  done
  echo ""
fi

echo -e "${C}--------------------------------------------------------------${NC}"
echo -e "  Checked: $CHECKED    Updates: ${#UPDATES[@]}    Errors: ${#ERRORS[@]}"
echo -e "  $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${C}--------------------------------------------------------------${NC}"
echo ""

#-------------------------------------------------------------------------------
# Notification via OpenClaw messaging
#-------------------------------------------------------------------------------
if [ -n "$NOTIFY_PHONE" ] && [ $HAS_UPDATES -eq 1 ]; then
  msg="Franchise Update Check - ${#UPDATES[@]} update(s) available:"
  for entry in "${UPDATES[@]}"; do
    IFS='|' read -r component current available <<< "$entry"
    msg="$msg
- $component: $current -> $available"
  done
  if openclaw message send "$NOTIFY_PHONE" "$msg" &>/dev/null; then
    echo -e "  ${G}Notification sent to $NOTIFY_PHONE${NC}"
  else
    echo -e "  ${R}Failed to send notification to $NOTIFY_PHONE${NC}"
  fi
  echo ""
fi

exit $HAS_UPDATES

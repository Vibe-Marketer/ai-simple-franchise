#!/bin/bash
#===============================================================================
# OpenClaw Franchise Restore
# Restores an OpenClaw backup tarball created by backup.sh.
#
# Usage:
#   ./restore.sh <backup-file.tar.gz> [--dry-run] [--help]
#
# Options:
#   --dry-run   Show what would be restored without making changes
#   --help      Show this help message
#
# Safety: Creates a pre-restore backup before overwriting any files.
#===============================================================================

set -u
set -o pipefail

#-------------------------------------------------------------------------------
# Colors (consistent with installer style)
#-------------------------------------------------------------------------------
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  B='\033[0;34m'  C='\033[0;36m'  NC='\033[0m'

#-------------------------------------------------------------------------------
# Globals
#-------------------------------------------------------------------------------
TIMESTAMP="$(date +%Y-%m-%d-%H%M%S)"
OPENCLAW_DIR="$HOME/.openclaw"
BACKUP_DIR="$OPENCLAW_DIR/backups"
BACKUP_FILE=""
DRY_RUN=false
STAGING_DIR=""
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

#-------------------------------------------------------------------------------
# Parse args
#-------------------------------------------------------------------------------
POSITIONAL=()
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --help|-h)
      echo "Usage: $0 <backup-file.tar.gz> [--dry-run] [--help]"
      echo ""
      echo "Arguments:"
      echo "  backup-file.tar.gz   Path to the backup tarball (from backup.sh)"
      echo ""
      echo "Options:"
      echo "  --dry-run   Show what would be restored without making changes"
      echo "  --help      Show this help message"
      echo ""
      echo "Safety: A pre-restore backup is created automatically before extraction."
      exit 0 ;;
    -*) echo -e "${R}Unknown option: $1${NC}"; exit 1 ;;
    *)  POSITIONAL+=("$1"); shift ;;
  esac
done

if [ ${#POSITIONAL[@]} -eq 0 ]; then
  echo -e "${R}Error: No backup file specified.${NC}"
  echo ""
  echo "Usage: $0 <backup-file.tar.gz> [--dry-run]"
  echo ""
  # List available backups
  if [ -d "$BACKUP_DIR" ] && ls "$BACKUP_DIR"/backup-*.tar.gz &>/dev/null 2>&1; then
    echo -e "${C}Available backups in $BACKUP_DIR:${NC}"
    ls -1t "$BACKUP_DIR"/backup-*.tar.gz | while read -r f; do
      size="$(du -h "$f" | cut -f1)"
      echo "  $(basename "$f")  ($size)"
    done
    echo ""
  fi
  exit 1
fi

BACKUP_FILE="${POSITIONAL[0]}"

# Resolve relative paths
if [[ "$BACKUP_FILE" != /* ]]; then
  BACKUP_FILE="$(pwd)/$BACKUP_FILE"
fi

# Also check in default backup dir if file doesn't exist at given path
if [ ! -f "$BACKUP_FILE" ] && [ -f "$BACKUP_DIR/$BACKUP_FILE" ]; then
  BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILE"
fi
if [ ! -f "$BACKUP_FILE" ] && [ -f "$BACKUP_DIR/$(basename "$BACKUP_FILE")" ]; then
  BACKUP_FILE="$BACKUP_DIR/$(basename "$BACKUP_FILE")"
fi

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
ok()   { echo -e "  ${G}\xE2\x9C\x93${NC} $1"; }
fail() { echo -e "  ${R}\xE2\x9C\x97${NC} $1"; }
warn() { echo -e "  ${Y}\xE2\x9A\xA0${NC} $1"; }
info() { echo -e "  ${C}\xE2\x86\x92${NC} $1"; }
dry()  { echo -e "  ${Y}[DRY-RUN]${NC} Would: $1"; }

cleanup() {
  if [ -n "$STAGING_DIR" ] && [ -d "$STAGING_DIR" ]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

#-------------------------------------------------------------------------------
# Banner
#-------------------------------------------------------------------------------
echo ""
echo -e "${C}+--------------------------------------------------------------+${NC}"
echo -e "${C}|           OpenClaw Franchise Restore                         |${NC}"
echo -e "${C}+--------------------------------------------------------------+${NC}"
echo ""
echo -e "  Backup:     ${C}$(basename "$BACKUP_FILE")${NC}"
echo -e "  Target:     ${C}${OPENCLAW_DIR}${NC}"
echo -e "  Timestamp:  ${C}${TIMESTAMP}${NC}"
$DRY_RUN && echo -e "  Mode:       ${Y}DRY RUN${NC}"
echo ""

#===============================================================================
# Step 1: Validate backup file
#===============================================================================
echo -e "${C}Validating Backup${NC}"

if [ ! -f "$BACKUP_FILE" ]; then
  fail "Backup file not found: $BACKUP_FILE"
  exit 1
fi
ok "Backup file exists"

# Check it's a valid gzip tarball
if ! file "$BACKUP_FILE" | grep -q "gzip"; then
  fail "File does not appear to be a gzip archive"
  exit 1
fi
ok "Valid gzip archive"

# Extract to staging to inspect contents
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-restore-XXXXXX")"
info "Extracting to staging area for verification..."

if ! tar -xzf "$BACKUP_FILE" -C "$STAGING_DIR" 2>/dev/null; then
  fail "Failed to extract backup tarball"
  exit 1
fi
ok "Tarball extracted"

# Locate the backup root (should be openclaw-backup/)
RESTORE_ROOT=""
if [ -d "$STAGING_DIR/openclaw-backup" ]; then
  RESTORE_ROOT="$STAGING_DIR/openclaw-backup"
else
  # Try to find it
  for d in "$STAGING_DIR"/*/; do
    if [ -d "$d" ]; then
      RESTORE_ROOT="${d%/}"
      break
    fi
  done
fi

if [ -z "$RESTORE_ROOT" ] || [ ! -d "$RESTORE_ROOT" ]; then
  fail "Could not find backup root directory in tarball"
  exit 1
fi

#===============================================================================
# Step 2: Verify expected content
#===============================================================================
echo ""
echo -e "${C}Verifying Backup Contents${NC}"

EXPECTED_ITEMS=0
FOUND_ITEMS=0

verify_item() {
  local path="$1"
  local label="$2"
  local required="${3:-false}"
  EXPECTED_ITEMS=$((EXPECTED_ITEMS + 1))

  if [ -e "$RESTORE_ROOT/$path" ]; then
    ok "$label"
    FOUND_ITEMS=$((FOUND_ITEMS + 1))
  elif [ "$required" = "true" ]; then
    fail "$label (MISSING - required)"
  else
    warn "$label (not in backup)"
  fi
}

verify_item "MANIFEST.txt" "Backup manifest"
verify_item "openclaw.json" "openclaw.json" "true"
verify_item ".env" "Root .env"
verify_item "workspace" "Workspace directory" "true"
verify_item "cron/jobs.json" "Cron jobs"
verify_item "credentials" "Credentials"
verify_item "extensions/openclaw-composio/config" "Composio config"
verify_item "extensions/openclaw-mem0/config" "Mem0 config"

# Check for memory databases
if ls "$RESTORE_ROOT"/memory/*.db &>/dev/null 2>&1 || ls "$RESTORE_ROOT"/memory/*.sqlite &>/dev/null 2>&1; then
  ok "Memory databases"
  FOUND_ITEMS=$((FOUND_ITEMS + 1))
else
  warn "Memory databases (not in backup)"
fi
EXPECTED_ITEMS=$((EXPECTED_ITEMS + 1))

# Check for Neo4j dump
HAS_NEO4J_DUMP=false
if [ -f "$RESTORE_ROOT/neo4j-dump.db" ]; then
  dump_size=$(stat -f%z "$RESTORE_ROOT/neo4j-dump.db" 2>/dev/null || stat --printf="%s" "$RESTORE_ROOT/neo4j-dump.db" 2>/dev/null || echo "0")
  if [ "$dump_size" -gt 0 ]; then
    ok "Neo4j database dump ($(du -h "$RESTORE_ROOT/neo4j-dump.db" | cut -f1))"
    HAS_NEO4J_DUMP=true
  else
    warn "Neo4j dump file is empty"
  fi
else
  warn "Neo4j database dump (not in backup)"
fi

echo ""
info "Verification: $FOUND_ITEMS of $EXPECTED_ITEMS expected items found"

# Show manifest if available
if [ -f "$RESTORE_ROOT/MANIFEST.txt" ]; then
  echo ""
  echo -e "${C}Backup Manifest:${NC}"
  while IFS= read -r line; do
    echo "    $line"
  done < "$RESTORE_ROOT/MANIFEST.txt"
fi

# List all files that will be restored
echo ""
echo -e "${C}Files to Restore:${NC}"
file_count=0
(cd "$RESTORE_ROOT" && find . -type f | sort | sed 's|^\./||') | while read -r f; do
  if [ "$f" = "MANIFEST.txt" ] || [ "$f" = "neo4j-dump.db" ]; then
    continue
  fi
  echo "    $f"
  file_count=$((file_count + 1))
done
total_files=$(($(cd "$RESTORE_ROOT" && find . -type f | wc -l | tr -d ' ')))
echo ""
info "Total files: $total_files"

#===============================================================================
# Dry run exits here
#===============================================================================
if $DRY_RUN; then
  echo ""
  echo -e "${Y}+--------------------------------------------------------------+${NC}"
  echo -e "${Y}|                     DRY RUN Complete                         |${NC}"
  echo -e "${Y}+--------------------------------------------------------------+${NC}"
  echo ""
  echo -e "  ${Y}No changes were made. Run without --dry-run to restore.${NC}"
  echo ""
  exit 0
fi

#===============================================================================
# Step 3: Confirm with user
#===============================================================================
echo ""
echo -e "${Y}This will overwrite existing files in $OPENCLAW_DIR${NC}"
echo -e "${Y}A pre-restore backup will be created first.${NC}"
echo ""
read -r -p "  Proceed with restore? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
  info "Restore cancelled."
  exit 0
fi
echo ""

#===============================================================================
# Step 4: Create pre-restore backup (safety net)
#===============================================================================
echo -e "${C}Creating Pre-Restore Safety Backup${NC}"

PRE_RESTORE_FILE="$BACKUP_DIR/pre-restore-${TIMESTAMP}.tar.gz"
mkdir -p "$BACKUP_DIR"

BACKUP_SCRIPT="$SCRIPT_DIR/backup.sh"
if [ -x "$BACKUP_SCRIPT" ]; then
  info "Running backup.sh for safety snapshot..."
  if bash "$BACKUP_SCRIPT" --output "$PRE_RESTORE_FILE" >/dev/null 2>&1; then
    ok "Pre-restore backup: $(basename "$PRE_RESTORE_FILE") ($(du -h "$PRE_RESTORE_FILE" | cut -f1))"
  else
    warn "Pre-restore backup failed (backup.sh returned non-zero)"
    info "Falling back to quick tarball of critical files..."
    # Quick fallback: tar up the most critical files
    tar -czf "$PRE_RESTORE_FILE" \
      -C "$HOME" \
      .openclaw/openclaw.json \
      .openclaw/.env \
      .openclaw/cron/jobs.json \
      2>/dev/null
    if [ -f "$PRE_RESTORE_FILE" ]; then
      ok "Pre-restore backup (minimal): $(basename "$PRE_RESTORE_FILE")"
    else
      warn "Could not create pre-restore backup"
      read -r -p "  Continue without safety backup? [y/N] " confirm2
      if [[ ! "$confirm2" =~ ^[Yy]$ ]]; then
        info "Restore cancelled."
        exit 0
      fi
    fi
  fi
else
  # Fallback: quick tarball of critical files
  info "backup.sh not found at $BACKUP_SCRIPT, creating minimal safety backup..."
  tar -czf "$PRE_RESTORE_FILE" \
    -C "$HOME" \
    .openclaw/openclaw.json \
    .openclaw/.env \
    .openclaw/cron/jobs.json \
    2>/dev/null
  if [ -f "$PRE_RESTORE_FILE" ]; then
    ok "Pre-restore backup (minimal): $(basename "$PRE_RESTORE_FILE")"
  else
    warn "Could not create pre-restore backup"
  fi
fi

#===============================================================================
# Step 5: Restore files
#===============================================================================
echo ""
echo -e "${C}Restoring Files${NC}"

RESTORED=0
RESTORE_ERRORS=0

restore_file() {
  local src="$1"
  local dest="$2"
  local label="$3"

  mkdir -p "$(dirname "$dest")" 2>/dev/null
  if cp -a "$src" "$dest" 2>/dev/null; then
    ok "$label"
    RESTORED=$((RESTORED + 1))
  else
    fail "$label"
    RESTORE_ERRORS=$((RESTORE_ERRORS + 1))
  fi
}

restore_dir() {
  local src="$1"
  local dest="$2"
  local label="$3"

  if [ -d "$src" ]; then
    mkdir -p "$dest" 2>/dev/null
    if cp -a "$src/." "$dest/" 2>/dev/null; then
      local count
      count=$(find "$src" -type f | wc -l | tr -d ' ')
      ok "$label ($count files)"
      RESTORED=$((RESTORED + 1))
    else
      fail "$label"
      RESTORE_ERRORS=$((RESTORE_ERRORS + 1))
    fi
  fi
}

# --- Core config ---
if [ -f "$RESTORE_ROOT/openclaw.json" ]; then
  restore_file "$RESTORE_ROOT/openclaw.json" "$OPENCLAW_DIR/openclaw.json" "openclaw.json"
fi

if [ -f "$RESTORE_ROOT/.env" ]; then
  restore_file "$RESTORE_ROOT/.env" "$OPENCLAW_DIR/.env" ".env"
  chmod 600 "$OPENCLAW_DIR/.env" 2>/dev/null
fi

# --- Workspace ---
if [ -d "$RESTORE_ROOT/workspace" ]; then
  # Restore .md files
  for md_file in "$RESTORE_ROOT/workspace/"*.md; do
    if [ -f "$md_file" ]; then
      fname="$(basename "$md_file")"
      restore_file "$md_file" "$OPENCLAW_DIR/workspace/$fname" "workspace/$fname"
    fi
  done

  # Restore workspace/.env
  if [ -f "$RESTORE_ROOT/workspace/.env" ]; then
    restore_file "$RESTORE_ROOT/workspace/.env" "$OPENCLAW_DIR/workspace/.env" "workspace/.env"
    chmod 600 "$OPENCLAW_DIR/workspace/.env" 2>/dev/null
  fi

  # Restore workspace subdirs (scripts, skills, memory)
  for subdir in scripts skills memory; do
    if [ -d "$RESTORE_ROOT/workspace/$subdir" ]; then
      restore_dir "$RESTORE_ROOT/workspace/$subdir" "$OPENCLAW_DIR/workspace/$subdir" "workspace/$subdir"
    fi
  done
fi

# --- Specialist workspaces ---
for ws_dir in "$RESTORE_ROOT"/workspace-*/; do
  if [ -d "$ws_dir" ]; then
    ws_name="$(basename "$ws_dir")"
    restore_dir "$ws_dir" "$OPENCLAW_DIR/$ws_name" "$ws_name"
  fi
done

# --- Memory ---
if [ -d "$RESTORE_ROOT/memory" ]; then
  restore_dir "$RESTORE_ROOT/memory" "$OPENCLAW_DIR/memory" "memory"
fi

# --- Extension configs ---
if [ -d "$RESTORE_ROOT/extensions/openclaw-composio/config" ]; then
  restore_dir "$RESTORE_ROOT/extensions/openclaw-composio/config" \
    "$OPENCLAW_DIR/extensions/openclaw-composio/config" "extensions/openclaw-composio/config"
fi

if [ -d "$RESTORE_ROOT/extensions/openclaw-mem0/config" ]; then
  restore_dir "$RESTORE_ROOT/extensions/openclaw-mem0/config" \
    "$OPENCLAW_DIR/extensions/openclaw-mem0/config" "extensions/openclaw-mem0/config"
fi

# --- Cron ---
if [ -f "$RESTORE_ROOT/cron/jobs.json" ]; then
  restore_file "$RESTORE_ROOT/cron/jobs.json" "$OPENCLAW_DIR/cron/jobs.json" "cron/jobs.json"
fi

# --- Credentials ---
if [ -d "$RESTORE_ROOT/credentials" ]; then
  restore_dir "$RESTORE_ROOT/credentials" "$OPENCLAW_DIR/credentials" "credentials"
  # Ensure restrictive permissions on credential files
  chmod -R go-rwx "$OPENCLAW_DIR/credentials" 2>/dev/null
fi

#===============================================================================
# Step 6: Neo4j restore (if dump exists)
#===============================================================================
echo ""
echo -e "${C}Neo4j Database${NC}"

if $HAS_NEO4J_DUMP; then
  if docker info &>/dev/null 2>&1; then
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^neo4j$'; then
      info "Restoring Neo4j database from dump..."
      # Stop the Neo4j container to load the dump
      info "Stopping Neo4j container..."
      docker stop neo4j >/dev/null 2>&1

      # Load the dump
      if docker run --rm \
        -v "$OPENCLAW_DIR/neo4j/data:/data" \
        -v "$RESTORE_ROOT:/backup" \
        neo4j:community \
        neo4j-admin database load neo4j --from-stdin < "$RESTORE_ROOT/neo4j-dump.db" 2>/dev/null; then
        ok "Neo4j database restored from dump"
      else
        # Try alternative load method
        warn "Stdin load failed, trying file-based load..."
        if docker run --rm \
          -v "$OPENCLAW_DIR/neo4j/data:/data" \
          -v "$RESTORE_ROOT:/backup" \
          neo4j:community \
          neo4j-admin database load neo4j --from-path=/backup/neo4j-dump.db --overwrite-destination=true 2>/dev/null; then
          ok "Neo4j database restored (file-based method)"
        else
          warn "Neo4j restore failed. Manual restore may be needed:"
          info "  docker cp $RESTORE_ROOT/neo4j-dump.db neo4j:/tmp/"
          info "  docker exec neo4j neo4j-admin database load neo4j --from-path=/tmp/neo4j-dump.db --overwrite-destination=true"
        fi
      fi

      # Restart Neo4j
      info "Starting Neo4j container..."
      docker start neo4j >/dev/null 2>&1
      if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^neo4j$'; then
        ok "Neo4j container restarted"
      else
        fail "Neo4j container failed to restart"
      fi
    else
      warn "Neo4j container not found (skipping database restore)"
      info "Create the container first, then manually load the dump"
    fi
  else
    warn "Docker not running (skipping Neo4j restore)"
    info "Start Docker, then manually restore with the dump file"
  fi
else
  info "No Neo4j dump in backup (skipping)"
fi

#===============================================================================
# Step 7: Restart LaunchAgents
#===============================================================================
echo ""
echo -e "${C}Restarting LaunchAgents${NC}"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

restart_agent() {
  local label="$1"
  local plist="$LAUNCH_AGENTS_DIR/${label}.plist"

  if [ ! -f "$plist" ]; then
    warn "$label — plist not found"
    return
  fi

  # Unload (ignore errors if not currently loaded)
  launchctl unload "$plist" 2>/dev/null

  # Small delay to ensure clean unload
  sleep 1

  # Reload
  if launchctl load "$plist" 2>/dev/null; then
    ok "$label reloaded"
  else
    warn "$label failed to load (may need manual: launchctl load $plist)"
  fi
}

restart_agent "ai.openclaw.node"
restart_agent "ai.openclaw.gateway"

#===============================================================================
# Step 8: Health check
#===============================================================================
echo ""
echo -e "${C}Post-Restore Health Check${NC}"

HEALTHCHECK=""
# Look for healthcheck.sh relative to this script (sibling in franchise dir)
if [ -x "$SCRIPT_DIR/../healthcheck.sh" ]; then
  HEALTHCHECK="$SCRIPT_DIR/../healthcheck.sh"
elif [ -x "$SCRIPT_DIR/healthcheck.sh" ]; then
  HEALTHCHECK="$SCRIPT_DIR/healthcheck.sh"
fi

if [ -n "$HEALTHCHECK" ]; then
  info "Running health check..."
  echo ""
  bash "$HEALTHCHECK" 2>/dev/null
  HC_EXIT=$?
  echo ""
  if [ $HC_EXIT -eq 0 ]; then
    ok "Health check passed"
  else
    warn "Health check reported issues (exit code: $HC_EXIT)"
  fi
else
  # Inline quick health check
  info "Running quick health check..."
  HC_PASS=0
  HC_FAIL=0

  hc() {
    local label="$1"
    shift
    if "$@" &>/dev/null 2>&1; then
      ok "$label"
      HC_PASS=$((HC_PASS + 1))
    else
      fail "$label"
      HC_FAIL=$((HC_FAIL + 1))
    fi
  }

  hc "openclaw.json exists" test -f "$OPENCLAW_DIR/openclaw.json"
  hc ".env exists" test -f "$OPENCLAW_DIR/.env"
  hc "Workspace directory" test -d "$OPENCLAW_DIR/workspace"
  hc "AGENTS.md exists" test -f "$OPENCLAW_DIR/workspace/AGENTS.md"
  hc "Cron jobs.json" test -f "$OPENCLAW_DIR/cron/jobs.json"
  hc "Mem0 vectors DB" test -f "$OPENCLAW_DIR/memory/mem0-vectors.db"
  hc "Composio entity-map" test -f "$OPENCLAW_DIR/extensions/openclaw-composio/config/entity-map.json"
  hc "Mem0 identity-map" test -f "$OPENCLAW_DIR/extensions/openclaw-mem0/config/identity-map.json"

  echo ""
  info "Health: $HC_PASS passed, $HC_FAIL failed"
fi

#===============================================================================
# Summary
#===============================================================================
echo ""
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo -e "${G}|                    Restore Complete                          |${NC}"
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo ""
echo -e "  Source:         ${C}$(basename "$BACKUP_FILE")${NC}"
echo -e "  Items restored: ${G}${RESTORED}${NC}"
if [ $RESTORE_ERRORS -gt 0 ]; then
  echo -e "  Errors:         ${R}${RESTORE_ERRORS}${NC}"
fi
echo -e "  Safety backup:  ${C}$(basename "$PRE_RESTORE_FILE")${NC}"
echo ""

if [ $RESTORE_ERRORS -eq 0 ]; then
  echo -e "  ${G}All files restored successfully.${NC}"
else
  echo -e "  ${Y}Some files could not be restored. Check output above.${NC}"
fi
echo ""

exit $RESTORE_ERRORS

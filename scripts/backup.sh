#!/bin/bash
#===============================================================================
# OpenClaw Franchise Backup
# Creates a timestamped backup of all OpenClaw configuration, workspace files,
# memory databases, extensions config, cron jobs, and credentials.
#
# Usage:
#   ./backup.sh [--output PATH] [--help]
#
# Options:
#   --output PATH   Save backup tarball to PATH instead of ~/.openclaw/backups/
#   --help          Show this help message
#
# Keeps last 7 daily backups by default, rotating older ones.
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
DATE="$(date +%Y-%m-%d)"
OPENCLAW_DIR="$HOME/.openclaw"
BACKUP_DIR="$OPENCLAW_DIR/backups"
OUTPUT_PATH=""
KEEP_BACKUPS=7
STAGING_DIR=""

#-------------------------------------------------------------------------------
# Parse args
#-------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      if [ -z "${2:-}" ]; then
        echo -e "${R}Error: --output requires a path${NC}"
        exit 1
      fi
      OUTPUT_PATH="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--output PATH] [--help]"
      echo ""
      echo "Options:"
      echo "  --output PATH   Save backup tarball to PATH instead of ~/.openclaw/backups/"
      echo "  --help          Show this help message"
      echo ""
      echo "Creates a timestamped tarball of all OpenClaw config, workspace, memory,"
      echo "extensions, cron, and credentials. Keeps last 7 daily backups."
      exit 0 ;;
    *) echo -e "${R}Unknown option: $1${NC}"; exit 1 ;;
  esac
done

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
ok()   { echo -e "  ${G}\xE2\x9C\x93${NC} $1"; }
fail() { echo -e "  ${R}\xE2\x9C\x97${NC} $1"; }
warn() { echo -e "  ${Y}\xE2\x9A\xA0${NC} $1"; }
info() { echo -e "  ${C}\xE2\x86\x92${NC} $1"; }

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
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo -e "${G}|           OpenClaw Franchise Backup                          |${NC}"
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo ""
echo -e "  Timestamp:  ${C}${TIMESTAMP}${NC}"
echo -e "  Source:      ${C}${OPENCLAW_DIR}${NC}"
echo ""

#-------------------------------------------------------------------------------
# Validate source directory
#-------------------------------------------------------------------------------
if [ ! -d "$OPENCLAW_DIR" ]; then
  fail "OpenClaw directory not found at $OPENCLAW_DIR"
  echo -e "\n  ${R}Nothing to back up. Is OpenClaw installed?${NC}"
  exit 1
fi

#-------------------------------------------------------------------------------
# Determine output location
#-------------------------------------------------------------------------------
if [ -n "$OUTPUT_PATH" ]; then
  # If OUTPUT_PATH is a directory, put the tarball inside it
  if [ -d "$OUTPUT_PATH" ]; then
    BACKUP_FILE="$OUTPUT_PATH/backup-${TIMESTAMP}.tar.gz"
  else
    # Treat as full file path
    BACKUP_FILE="$OUTPUT_PATH"
  fi
  BACKUP_OUTPUT_DIR="$(dirname "$BACKUP_FILE")"
else
  BACKUP_OUTPUT_DIR="$BACKUP_DIR"
  BACKUP_FILE="$BACKUP_DIR/backup-${TIMESTAMP}.tar.gz"
fi

mkdir -p "$BACKUP_OUTPUT_DIR" 2>/dev/null
if [ ! -d "$BACKUP_OUTPUT_DIR" ]; then
  fail "Cannot create backup directory: $BACKUP_OUTPUT_DIR"
  exit 1
fi

info "Backup will be saved to: $BACKUP_FILE"
echo ""

#-------------------------------------------------------------------------------
# Create staging directory
#-------------------------------------------------------------------------------
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-backup-XXXXXX")"
STAGE="$STAGING_DIR/openclaw-backup"
mkdir -p "$STAGE"

ITEMS_BACKED=0
ITEMS_SKIPPED=0

#-------------------------------------------------------------------------------
# Helper: stage a file
#-------------------------------------------------------------------------------
stage_file() {
  local src="$1"
  local dest_relative="$2"
  local dest="$STAGE/$dest_relative"

  if [ -f "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp -a "$src" "$dest" 2>/dev/null
    if [ $? -eq 0 ]; then
      ok "$dest_relative"
      ITEMS_BACKED=$((ITEMS_BACKED + 1))
    else
      fail "$dest_relative (copy failed)"
    fi
  else
    warn "$dest_relative (not found, skipping)"
    ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
  fi
}

#-------------------------------------------------------------------------------
# Helper: stage a directory (with optional filter)
#-------------------------------------------------------------------------------
stage_dir() {
  local src="$1"
  local dest_relative="$2"
  local filter="${3:-}"  # optional: glob pattern like "*.md"
  local dest="$STAGE/$dest_relative"

  if [ -d "$src" ]; then
    mkdir -p "$dest"
    if [ -n "$filter" ]; then
      # Use find with specific patterns
      local found=0
      while IFS= read -r -d '' f; do
        local rel="${f#$src/}"
        local target_dir="$(dirname "$dest/$rel")"
        mkdir -p "$target_dir"
        cp -a "$f" "$dest/$rel" 2>/dev/null
        found=$((found + 1))
      done < <(find "$src" -maxdepth 1 -name "$filter" -print0 2>/dev/null)
      if [ $found -gt 0 ]; then
        ok "$dest_relative ($found files matching '$filter')"
        ITEMS_BACKED=$((ITEMS_BACKED + 1))
      else
        warn "$dest_relative (no files matching '$filter')"
        ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
      fi
    else
      cp -a "$src/." "$dest/" 2>/dev/null
      if [ $? -eq 0 ]; then
        ok "$dest_relative"
        ITEMS_BACKED=$((ITEMS_BACKED + 1))
      else
        fail "$dest_relative (copy failed)"
      fi
    fi
  else
    warn "$dest_relative (not found, skipping)"
    ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
  fi
}

#===============================================================================
# Stage files for backup
#===============================================================================

echo -e "${C}Core Configuration${NC}"
stage_file "$OPENCLAW_DIR/openclaw.json" "openclaw.json"
stage_file "$OPENCLAW_DIR/.env" ".env"
stage_file "$OPENCLAW_DIR/workspace/.env" "workspace/.env"

echo ""
echo -e "${C}Workspace Files${NC}"

# .md files from workspace root
if [ -d "$OPENCLAW_DIR/workspace" ]; then
  md_count=0
  while IFS= read -r -d '' f; do
    fname="$(basename "$f")"
    stage_file "$f" "workspace/$fname"
    md_count=$((md_count + 1))
  done < <(find "$OPENCLAW_DIR/workspace" -maxdepth 1 -name "*.md" -print0 2>/dev/null)
  if [ $md_count -eq 0 ]; then
    warn "workspace/*.md (no .md files found)"
  fi
else
  warn "workspace/ directory not found"
fi

# Workspace subdirectories: scripts/, skills/, memory/
for subdir in scripts skills memory; do
  if [ -d "$OPENCLAW_DIR/workspace/$subdir" ]; then
    stage_dir "$OPENCLAW_DIR/workspace/$subdir" "workspace/$subdir"
  else
    warn "workspace/$subdir/ (not found, skipping)"
    ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
  fi
done

echo ""
echo -e "${C}Specialist Workspaces${NC}"

# workspace-* directories
for ws_dir in "$OPENCLAW_DIR"/workspace-*/; do
  if [ -d "$ws_dir" ]; then
    ws_name="$(basename "$ws_dir")"
    stage_dir "$ws_dir" "$ws_name"
  fi
done
# Check if any were found
if ! ls -d "$OPENCLAW_DIR"/workspace-*/ &>/dev/null 2>&1; then
  warn "No specialist workspaces (workspace-*/) found"
  ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
fi

echo ""
echo -e "${C}Memory System${NC}"

# Memory databases (NOT neo4j data dir)
if [ -d "$OPENCLAW_DIR/memory" ]; then
  mkdir -p "$STAGE/memory"
  mem_count=0
  for db_file in "$OPENCLAW_DIR/memory/"*.db "$OPENCLAW_DIR/memory/"*.sqlite "$OPENCLAW_DIR/memory/"*.json; do
    if [ -f "$db_file" ]; then
      fname="$(basename "$db_file")"
      cp -a "$db_file" "$STAGE/memory/$fname" 2>/dev/null
      ok "memory/$fname"
      mem_count=$((mem_count + 1))
    fi
  done
  # Also grab README.md if present
  if [ -f "$OPENCLAW_DIR/memory/README.md" ]; then
    cp -a "$OPENCLAW_DIR/memory/README.md" "$STAGE/memory/README.md" 2>/dev/null
  fi
  # Copy subdirectories (digests, logs) but NOT large caches
  for mem_subdir in digests logs; do
    if [ -d "$OPENCLAW_DIR/memory/$mem_subdir" ]; then
      stage_dir "$OPENCLAW_DIR/memory/$mem_subdir" "memory/$mem_subdir"
    fi
  done
  if [ $mem_count -gt 0 ]; then
    ITEMS_BACKED=$((ITEMS_BACKED + 1))
  else
    warn "memory/ (no database files found)"
    ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
  fi
else
  warn "memory/ directory not found"
  ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
fi

echo ""
echo -e "${C}Extension Configs${NC}"

stage_dir "$OPENCLAW_DIR/extensions/openclaw-composio/config" "extensions/openclaw-composio/config"
stage_dir "$OPENCLAW_DIR/extensions/openclaw-mem0/config" "extensions/openclaw-mem0/config"

echo ""
echo -e "${C}Cron Jobs${NC}"

stage_file "$OPENCLAW_DIR/cron/jobs.json" "cron/jobs.json"

echo ""
echo -e "${C}Credentials${NC}"

if [ -d "$OPENCLAW_DIR/credentials" ]; then
  stage_dir "$OPENCLAW_DIR/credentials" "credentials"
else
  warn "credentials/ directory not found"
  ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
fi

#===============================================================================
# Neo4j database dump (if Docker is running)
#===============================================================================
echo ""
echo -e "${C}Neo4j Database${NC}"

if docker info &>/dev/null 2>&1; then
  if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^neo4j$'; then
    info "Neo4j container is running, creating database dump..."
    NEO4J_DUMP_FILE="$STAGE/neo4j-dump.db"
    if docker exec neo4j neo4j-admin database dump neo4j --to-stdout > "$NEO4J_DUMP_FILE" 2>/dev/null; then
      # Verify the dump file is non-empty
      dump_size=$(stat -f%z "$NEO4J_DUMP_FILE" 2>/dev/null || stat --printf="%s" "$NEO4J_DUMP_FILE" 2>/dev/null || echo "0")
      if [ "$dump_size" -gt 0 ]; then
        ok "Neo4j database dump ($(du -h "$NEO4J_DUMP_FILE" | cut -f1))"
        ITEMS_BACKED=$((ITEMS_BACKED + 1))
      else
        warn "Neo4j dump file is empty (database may be empty or dump command failed)"
        rm -f "$NEO4J_DUMP_FILE"
        ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
      fi
    else
      warn "Neo4j dump failed (neo4j-admin may not support --to-stdout in this version)"
      info "Try manual dump: docker exec neo4j neo4j-admin database dump neo4j"
      rm -f "$NEO4J_DUMP_FILE"
      ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
    fi
  else
    warn "Neo4j container not running (skipping database dump)"
    ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
  fi
else
  warn "Docker not running (skipping Neo4j dump)"
  ITEMS_SKIPPED=$((ITEMS_SKIPPED + 1))
fi

#===============================================================================
# Write backup manifest
#===============================================================================
echo ""
echo -e "${C}Creating Manifest${NC}"

MANIFEST="$STAGE/MANIFEST.txt"
{
  echo "OpenClaw Franchise Backup"
  echo "========================"
  echo "Timestamp: $TIMESTAMP"
  echo "Date:      $DATE"
  echo "Hostname:  $(hostname)"
  echo "User:      $(whoami)"
  echo "macOS:     $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
  echo ""
  echo "Contents:"
  (cd "$STAGE" && find . -type f | sort | sed 's|^\./||')
} > "$MANIFEST"
ok "MANIFEST.txt"

#===============================================================================
# Create tarball
#===============================================================================
echo ""
echo -e "${C}Compressing Backup${NC}"

if tar -czf "$BACKUP_FILE" -C "$STAGING_DIR" "openclaw-backup" 2>/dev/null; then
  ok "Created $BACKUP_FILE"
else
  fail "Failed to create tarball"
  exit 1
fi

#===============================================================================
# Rotate old backups (keep last N)
#===============================================================================
if [ -z "$OUTPUT_PATH" ]; then
  echo ""
  echo -e "${C}Backup Rotation${NC}"

  # Count existing backups
  backup_count=$(ls -1 "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | wc -l | tr -d ' ')
  if [ "$backup_count" -gt "$KEEP_BACKUPS" ]; then
    rotate_count=$((backup_count - KEEP_BACKUPS))
    info "Found $backup_count backups, keeping last $KEEP_BACKUPS, removing $rotate_count"
    ls -1t "$BACKUP_DIR"/backup-*.tar.gz 2>/dev/null | tail -n "$rotate_count" | while read -r old_backup; do
      rm -f "$old_backup"
      ok "Rotated: $(basename "$old_backup")"
    done
  else
    info "Backup count ($backup_count) within limit ($KEEP_BACKUPS), no rotation needed"
  fi
fi

#===============================================================================
# Summary
#===============================================================================
BACKUP_SIZE="$(du -h "$BACKUP_FILE" | cut -f1)"

echo ""
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo -e "${G}|                     Backup Complete                          |${NC}"
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo ""
echo -e "  File:     ${C}${BACKUP_FILE}${NC}"
echo -e "  Size:     ${C}${BACKUP_SIZE}${NC}"
echo -e "  Items:    ${G}${ITEMS_BACKED} backed up${NC}, ${Y}${ITEMS_SKIPPED} skipped${NC}"
echo -e "  Manifest: ${C}Included in tarball as MANIFEST.txt${NC}"
echo ""

exit 0

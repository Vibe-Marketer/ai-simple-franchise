#!/bin/bash
#===============================================================================
# OpenClaw Franchise Updater
# Pulls the latest franchise code from GitHub and selectively re-applies only
# changed components WITHOUT touching client-specific files.
#
# Usage:
#   ./update.sh [--dry-run] [--force] [--help]
#
# Designed to complement update-check.sh (which detects available updates).
# This script actually applies them.
#===============================================================================

set -u
set -o pipefail

#-------------------------------------------------------------------------------
# Globals
#-------------------------------------------------------------------------------
DATE="$(date +%Y-%m-%d)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FRANCHISE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OPENCLAW_DIR="$HOME/.openclaw"
WORKSPACE_DIR="$OPENCLAW_DIR/workspace"
LOG_DIR="$OPENCLAW_DIR/logs"
LOG_FILE="$LOG_DIR/update-${DATE}.log"
DRY_RUN=false
FORCE=false

# Tracking arrays
UPDATED=()
MANUAL_ACTION=()
NOT_TOUCHED=()

# Colors
R='\033[0;31m'  G='\033[0;32m'  Y='\033[1;33m'  B='\033[0;34m'  C='\033[0;36m'  NC='\033[0m'

#-------------------------------------------------------------------------------
# Parse args
#-------------------------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true; shift ;;
    --force)    FORCE=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--dry-run] [--force] [--help]"
      echo ""
      echo "Pulls the latest franchise code from GitHub and selectively re-applies"
      echo "only changed components WITHOUT touching client-specific files."
      echo ""
      echo "Options:"
      echo "  --dry-run    Show what would be updated without making changes"
      echo "  --force      Skip confirmation prompts"
      echo "  --help, -h   Show this help message"
      echo ""
      echo "Client-specific files that are NEVER touched:"
      echo "  .env, openclaw.json, IDENTITY.md, USER.md, SOUL.md, BUSINESS.md,"
      echo "  BOOTSTRAP.md, workspace/.env, .op-env, entity-map.json, cron/jobs.json"
      exit 0 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

#-------------------------------------------------------------------------------
# Helpers
#-------------------------------------------------------------------------------
mkdir -p "$LOG_DIR" 2>/dev/null

log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }

ok()   { echo -e "  ${G}+${NC} $1"; log "UPDATED: $1"; UPDATED+=("$1"); }
warn() { echo -e "  ${Y}!${NC} $1"; log "MANUAL: $1"; MANUAL_ACTION+=("$1"); }
info() { echo -e "  ${C}-${NC} $1"; log "INFO: $1"; }
dry()  { echo -e "  ${Y}[DRY-RUN]${NC} Would: $1"; log "DRY: $1"; UPDATED+=("$1 (dry)"); }

file_changed() {
  # Returns 0 (true) if a file was part of the changed set between old HEAD and new origin/main
  local relpath="$1"
  echo "$CHANGED_FILES" | grep -qF "$relpath"
}

copy_file() {
  local src="$1" dest="$2" label="$3"
  if $DRY_RUN; then
    dry "Copy $label"
  else
    local dest_dir
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir" 2>/dev/null
    if cp "$src" "$dest" 2>>"$LOG_FILE"; then
      ok "$label"
    else
      echo -e "  ${R}x${NC} Failed to copy: $label"
      log "FAIL: $label"
    fi
  fi
}

copy_and_chmod() {
  local src="$1" dest="$2" label="$3"
  if $DRY_RUN; then
    dry "Copy $label (+x)"
  else
    local dest_dir
    dest_dir="$(dirname "$dest")"
    mkdir -p "$dest_dir" 2>/dev/null
    if cp "$src" "$dest" 2>>"$LOG_FILE" && chmod +x "$dest" 2>>"$LOG_FILE"; then
      ok "$label"
    else
      echo -e "  ${R}x${NC} Failed to copy: $label"
      log "FAIL: $label"
    fi
  fi
}

#-------------------------------------------------------------------------------
# Banner
#-------------------------------------------------------------------------------
echo ""
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo -e "${G}|          OpenClaw Franchise Updater                          |${NC}"
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo ""
echo -e "  Date:          ${C}${DATE}${NC}"
echo -e "  Franchise dir: ${C}${FRANCHISE_DIR}${NC}"
echo -e "  Target:        ${C}${OPENCLAW_DIR}${NC}"
echo -e "  Log:           ${C}${LOG_FILE}${NC}"
$DRY_RUN && echo -e "  Mode:          ${Y}DRY RUN${NC}"
$FORCE   && echo -e "  Confirm:       ${Y}SKIPPED (--force)${NC}"
echo ""

log "=== Franchise Updater started | dry=$DRY_RUN | force=$FORCE ==="

#===============================================================================
# PRE-FLIGHT CHECKS
#===============================================================================
echo -e "${B}--- Pre-flight checks ---${NC}"

# 1. git available
if ! command -v git &>/dev/null; then
  echo -e "  ${R}x${NC} git is not installed or not in PATH"
  exit 1
fi
info "git found: $(git --version)"

# 2. We are in a git repo
if [ ! -d "$FRANCHISE_DIR/.git" ]; then
  echo -e "  ${R}x${NC} $FRANCHISE_DIR is not a git repository"
  echo -e "  ${C}-${NC} The update script must be run from within the franchise installer repo."
  exit 1
fi
info "Git repo confirmed: $FRANCHISE_DIR"

# 3. Remote is reachable
echo -e "  ${C}-${NC} Checking remote connectivity..."
if ! git -C "$FRANCHISE_DIR" ls-remote origin HEAD &>/dev/null 2>&1; then
  echo -e "  ${R}x${NC} Cannot reach git remote 'origin'"
  echo -e "  ${C}-${NC} Check your network connection or SSH/HTTPS credentials."
  exit 1
fi
info "Remote 'origin' is reachable"

# 4. Fetch latest refs
echo -e "  ${C}-${NC} Fetching latest from origin..."
if ! git -C "$FRANCHISE_DIR" fetch origin main >>"$LOG_FILE" 2>&1; then
  echo -e "  ${R}x${NC} git fetch origin main failed"
  exit 1
fi
info "Fetch complete"

# 5. Check if there are new commits
LOCAL_HEAD="$(git -C "$FRANCHISE_DIR" rev-parse HEAD 2>/dev/null)"
REMOTE_HEAD="$(git -C "$FRANCHISE_DIR" rev-parse origin/main 2>/dev/null)"

if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ]; then
  if ! $FORCE; then
    echo ""
    echo -e "  ${G}Already up to date.${NC}"
    echo -e "  Local:  ${C}${LOCAL_HEAD:0:12}${NC}"
    echo -e "  Remote: ${C}${REMOTE_HEAD:0:12}${NC}"
    echo ""
    log "No updates available. Exiting."
    exit 0
  else
    echo -e "  ${Y}!${NC} Already up to date, but --force specified. Continuing."
  fi
fi

echo ""

#===============================================================================
# SHOW WHAT CHANGED
#===============================================================================
echo -e "${B}--- Changes available ---${NC}"
echo ""

# New commits
COMMIT_LOG="$(git -C "$FRANCHISE_DIR" log HEAD..origin/main --oneline 2>/dev/null)"
COMMIT_COUNT="$(echo "$COMMIT_LOG" | grep -c . 2>/dev/null || echo 0)"
echo -e "  ${C}New commits (${COMMIT_COUNT}):${NC}"
echo "$COMMIT_LOG" | while IFS= read -r line; do
  echo -e "    $line"
done
echo ""

# File-level diff summary
DIFF_STAT="$(git -C "$FRANCHISE_DIR" diff --stat HEAD..origin/main 2>/dev/null)"
echo -e "  ${C}Changed files:${NC}"
echo "$DIFF_STAT" | while IFS= read -r line; do
  echo -e "    $line"
done
echo ""

# Get list of changed file paths for selective update logic
CHANGED_FILES="$(git -C "$FRANCHISE_DIR" diff --name-only HEAD..origin/main 2>/dev/null)"

# Ask for confirmation unless --force
if ! $FORCE && ! $DRY_RUN; then
  echo -n -e "  ${Y}Apply these updates? [y/N]${NC} "
  read -r confirm
  case "$confirm" in
    [yY]|[yY][eE][sS]) ;;
    *)
      echo -e "  ${C}-${NC} Update cancelled."
      log "Update cancelled by user."
      exit 0
      ;;
  esac
  echo ""
fi

#===============================================================================
# PULL THE UPDATE
#===============================================================================
echo -e "${B}--- Pulling update ---${NC}"

if $DRY_RUN; then
  echo -e "  ${Y}[DRY-RUN]${NC} Would: git pull origin main"
else
  if git -C "$FRANCHISE_DIR" pull origin main >>"$LOG_FILE" 2>&1; then
    info "git pull origin main succeeded"
  else
    echo -e "  ${R}x${NC} git pull origin main failed. Check $LOG_FILE"
    echo -e "  ${C}-${NC} You may need to resolve merge conflicts manually."
    exit 1
  fi
fi

# Record the new version
NEW_VERSION="$(grep '^VERSION=' "$FRANCHISE_DIR/install.sh" 2>/dev/null | head -1 | cut -d'"' -f2)"
if [ -n "$NEW_VERSION" ]; then
  info "Franchise version: $NEW_VERSION"
fi
echo ""

#===============================================================================
# SELECTIVELY RE-APPLY CHANGED COMPONENTS
#===============================================================================

# --------------------------------------------------------------------------
# 6a. Scripts — Always update (safe, no client-specific content)
# --------------------------------------------------------------------------
echo -e "${B}--- Scripts ---${NC}"

# scripts/*.sh -> ~/.openclaw/scripts/
UTIL_SCRIPTS=("backup.sh" "restore.sh" "update-check.sh" "launch-with-secrets.sh" "update.sh")
for script_name in "${UTIL_SCRIPTS[@]}"; do
  src="$FRANCHISE_DIR/scripts/$script_name"
  dest="$OPENCLAW_DIR/scripts/$script_name"
  if [ -f "$src" ]; then
    if file_changed "scripts/$script_name"; then
      copy_and_chmod "$src" "$dest" "scripts/$script_name"
    else
      if ! $FORCE; then
        info "scripts/$script_name (unchanged)"
      else
        copy_and_chmod "$src" "$dest" "scripts/$script_name"
      fi
    fi
  fi
done

# workspace/scripts/*.sh -> ~/.openclaw/workspace/scripts/
if [ -d "$FRANCHISE_DIR/workspace/scripts" ]; then
  for ws_script in "$FRANCHISE_DIR/workspace/scripts/"*.sh; do
    [ -f "$ws_script" ] || continue
    ws_name="$(basename "$ws_script")"
    dest="$WORKSPACE_DIR/scripts/$ws_name"
    if file_changed "workspace/scripts/$ws_name"; then
      copy_and_chmod "$ws_script" "$dest" "workspace/scripts/$ws_name"
    else
      if $FORCE; then
        copy_and_chmod "$ws_script" "$dest" "workspace/scripts/$ws_name"
      else
        info "workspace/scripts/$ws_name (unchanged)"
      fi
    fi
  done
fi

echo ""

# --------------------------------------------------------------------------
# 6b. Skills — Always update SKILL.md files (safe, no client content)
# --------------------------------------------------------------------------
echo -e "${B}--- Skills ---${NC}"

# Global skills: skills/*/SKILL.md -> ~/.openclaw/skills/*/SKILL.md
# Workspace skills: same -> ~/.openclaw/workspace/skills/*/SKILL.md
GLOBAL_SKILLS=("autonomous-brain" "calendly" "wacli")
WS_SKILLS=("dev-gsd" "sales-outreach" "viral-content")

for skill_name in "${GLOBAL_SKILLS[@]}"; do
  src="$FRANCHISE_DIR/skills/$skill_name/SKILL.md"
  dest="$OPENCLAW_DIR/skills/$skill_name/SKILL.md"
  if [ -f "$src" ]; then
    if file_changed "skills/$skill_name/SKILL.md" || $FORCE; then
      copy_file "$src" "$dest" "skills/$skill_name/SKILL.md"
    else
      info "skills/$skill_name/SKILL.md (unchanged)"
    fi
  fi

  # Also update any other non-SKILL.md files from franchise that are NOT client-customized
  # For safety, only copy files that exist in the franchise source AND were changed
  if [ -d "$FRANCHISE_DIR/skills/$skill_name" ]; then
    for skill_file in "$FRANCHISE_DIR/skills/$skill_name/"*; do
      [ -f "$skill_file" ] || continue
      sf_name="$(basename "$skill_file")"
      [ "$sf_name" = "SKILL.md" ] && continue  # already handled above
      if file_changed "skills/$skill_name/$sf_name" || $FORCE; then
        copy_file "$skill_file" "$OPENCLAW_DIR/skills/$skill_name/$sf_name" "skills/$skill_name/$sf_name"
      fi
    done
  fi
done

for skill_name in "${WS_SKILLS[@]}"; do
  src="$FRANCHISE_DIR/skills/$skill_name/SKILL.md"
  dest="$WORKSPACE_DIR/skills/$skill_name/SKILL.md"
  if [ -f "$src" ]; then
    if file_changed "skills/$skill_name/SKILL.md" || $FORCE; then
      copy_file "$src" "$dest" "workspace/skills/$skill_name/SKILL.md"
    else
      info "workspace/skills/$skill_name/SKILL.md (unchanged)"
    fi
  fi
done

echo ""

# --------------------------------------------------------------------------
# 6c. Workspace templates — ONLY update files that are NOT client-customized
# --------------------------------------------------------------------------
echo -e "${B}--- Workspace templates ---${NC}"

# SAFE to update (generic framework files)
SAFE_WORKSPACE_FILES=("AGENTS.md" "TOOLS.md" "HEARTBEAT.md")

# NEVER touch (client personalized)
# IDENTITY.md, USER.md, SOUL.md, BUSINESS.md, BOOTSTRAP.md

for wf in "${SAFE_WORKSPACE_FILES[@]}"; do
  src="$FRANCHISE_DIR/workspace/$wf"
  dest="$WORKSPACE_DIR/$wf"
  if [ -f "$src" ]; then
    if file_changed "workspace/$wf" || $FORCE; then
      copy_file "$src" "$dest" "workspace/$wf"
    else
      info "workspace/$wf (unchanged)"
    fi
  fi
done

# Specialist workspace AGENTS.md files (generic, safe to update)
# Mapping: workspaces/bizdev/AGENTS.md -> ~/.openclaw/workspace-bizdev/AGENTS.md
SPECIALIST_MAP=(
  "bizdev:workspace-bizdev"
  "content:workspace-content"
  "dev:workspace-dev"
  "outreach:workspace-outreach"
  "quick:workspace-quick"
)

for entry in "${SPECIALIST_MAP[@]}"; do
  IFS=':' read -r src_name dest_name <<< "$entry"
  src="$FRANCHISE_DIR/workspaces/$src_name/AGENTS.md"
  dest="$OPENCLAW_DIR/$dest_name/AGENTS.md"
  if [ -f "$src" ]; then
    if file_changed "workspaces/$src_name/AGENTS.md" || $FORCE; then
      copy_file "$src" "$dest" "workspaces/$src_name/AGENTS.md"
    else
      info "workspaces/$src_name/AGENTS.md (unchanged)"
    fi
  fi
done

echo ""

# --------------------------------------------------------------------------
# 6d. Cron jobs — Merge new jobs without losing client customizations
# --------------------------------------------------------------------------
echo -e "${B}--- Cron jobs ---${NC}"

CRON_SRC="$FRANCHISE_DIR/config/cron-jobs.template.json"
CRON_DEST="$OPENCLAW_DIR/cron/jobs.json"

if file_changed "config/cron-jobs.template.json" || $FORCE; then
  if [ -f "$CRON_DEST" ]; then
    # Client cron exists -- do NOT overwrite
    info "cron/jobs.json exists -- will NOT overwrite (client-customized)"
    if $DRY_RUN; then
      echo -e "  ${Y}[DRY-RUN]${NC} Would: show diff between template and installed jobs.json"
    else
      if command -v diff &>/dev/null; then
        echo -e "  ${C}Diff (template vs installed):${NC}"
        diff "$CRON_SRC" "$CRON_DEST" 2>/dev/null | head -40
        echo ""
      fi
      if $FORCE; then
        # Create a .new file alongside for manual merge
        cp "$CRON_SRC" "${CRON_DEST}.new" 2>>"$LOG_FILE"
        warn "Cron template changed -- review: diff $CRON_DEST ${CRON_DEST}.new"
      else
        warn "Cron template changed -- review manually: diff $CRON_DEST $CRON_SRC"
      fi
    fi
  else
    # No client cron yet -- safe to install
    copy_file "$CRON_SRC" "$CRON_DEST" "cron/jobs.json (new install)"
  fi
else
  info "cron-jobs.template.json (unchanged)"
fi

echo ""

# --------------------------------------------------------------------------
# 6e. LaunchAgent plists — Only update if templates changed
# --------------------------------------------------------------------------
echo -e "${B}--- LaunchAgent plists ---${NC}"

PLIST_TEMPLATES=(
  "launchagents/ai.openclaw.node.plist:ai.openclaw.node.plist"
  "launchagents/ai.openclaw.gateway.plist:ai.openclaw.gateway.plist"
  "launchagents/com.cloudflare.cloudflared.plist:com.cloudflare.cloudflared.plist"
)

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"

for entry in "${PLIST_TEMPLATES[@]}"; do
  IFS=':' read -r src_rel plist_name <<< "$entry"
  src="$FRANCHISE_DIR/$src_rel"
  dest="$LAUNCH_AGENTS_DIR/$plist_name"

  if [ ! -f "$src" ]; then
    continue
  fi

  if file_changed "$src_rel" || $FORCE; then
    if [ -f "$dest" ]; then
      # Compare the template with what is installed
      # Note: installed plists have templates already rendered, so a byte-for-byte
      # diff will always show differences. Instead, just warn about the template change.
      warn "Plist template changed: $plist_name -- reload with:"
      echo -e "    ${C}launchctl unload ~/Library/LaunchAgents/$plist_name${NC}"
      echo -e "    ${C}launchctl load ~/Library/LaunchAgents/$plist_name${NC}"
      info "Template source: $src"
      info "NOTE: Plist contains rendered paths. Re-run install.sh to regenerate, or update manually."
    else
      info "Plist template changed but $plist_name not installed yet -- run install.sh to generate"
    fi
  else
    info "$plist_name (template unchanged)"
  fi
done

echo ""

# --------------------------------------------------------------------------
# 6f. Brewfile — Just inform, don't auto-run
# --------------------------------------------------------------------------
echo -e "${B}--- Brewfile ---${NC}"

if file_changed "Brewfile" || $FORCE; then
  warn "Brewfile changed -- run: brew bundle --file=$FRANCHISE_DIR/Brewfile"
else
  info "Brewfile (unchanged)"
fi

echo ""

# --------------------------------------------------------------------------
# 6g. Patches — Check if patches need re-applying
# --------------------------------------------------------------------------
echo -e "${B}--- Patches ---${NC}"

VERIFY_PATCHES="$FRANCHISE_DIR/patches/verify-patches.sh"

if [ -f "$VERIFY_PATCHES" ] && [ -x "$VERIFY_PATCHES" ]; then
  if $DRY_RUN; then
    echo -e "  ${Y}[DRY-RUN]${NC} Would: run patches/verify-patches.sh"
  else
    info "Running patch verification..."
    if bash "$VERIFY_PATCHES" >>"$LOG_FILE" 2>&1; then
      info "All patches verified OK"
    else
      warn "Patches need re-applying -- run: $FRANCHISE_DIR/patches/verify-patches.sh"
      info "mem0 patches: $FRANCHISE_DIR/patches/apply-mem0-patches.sh"
      info "OpenClaw patches: $FRANCHISE_DIR/patches/apply-openclaw-patches.sh"
    fi
  fi
else
  # Check if any patch-related files changed
  PATCHES_CHANGED=false
  for pf in $(echo "$CHANGED_FILES" | grep '^patches/' 2>/dev/null); do
    PATCHES_CHANGED=true
    break
  done
  if $PATCHES_CHANGED; then
    warn "Patch files changed -- review and re-apply: $FRANCHISE_DIR/patches/"
  else
    info "Patch files (unchanged)"
  fi
fi

echo ""

# --------------------------------------------------------------------------
# 6h. Healthcheck — Always copy the latest healthcheck.sh
# --------------------------------------------------------------------------
echo -e "${B}--- Healthcheck ---${NC}"

HEALTHCHECK_SRC="$FRANCHISE_DIR/healthcheck.sh"
HEALTHCHECK_DEST="$OPENCLAW_DIR/scripts/healthcheck.sh"

if [ -f "$HEALTHCHECK_SRC" ]; then
  if file_changed "healthcheck.sh" || $FORCE; then
    copy_and_chmod "$HEALTHCHECK_SRC" "$HEALTHCHECK_DEST" "healthcheck.sh"
  else
    # Always copy healthcheck even if unchanged in the diff, to ensure latest is deployed
    copy_and_chmod "$HEALTHCHECK_SRC" "$HEALTHCHECK_DEST" "healthcheck.sh"
  fi
fi

echo ""

#===============================================================================
# POST-UPDATE
#===============================================================================
echo -e "${B}--- Post-update healthcheck ---${NC}"

if [ -f "$HEALTHCHECK_DEST" ] && [ -x "$HEALTHCHECK_DEST" ] && ! $DRY_RUN; then
  info "Running healthcheck..."
  if bash "$HEALTHCHECK_DEST" >>"$LOG_FILE" 2>&1; then
    info "Healthcheck passed"
  else
    warn "Healthcheck reported issues -- review: bash $HEALTHCHECK_DEST"
  fi
elif [ -f "$HEALTHCHECK_SRC" ] && [ -x "$HEALTHCHECK_SRC" ] && ! $DRY_RUN; then
  info "Running healthcheck from franchise repo..."
  if bash "$HEALTHCHECK_SRC" >>"$LOG_FILE" 2>&1; then
    info "Healthcheck passed"
  else
    warn "Healthcheck reported issues -- review: bash $HEALTHCHECK_SRC"
  fi
else
  if $DRY_RUN; then
    echo -e "  ${Y}[DRY-RUN]${NC} Would: run healthcheck.sh"
  else
    info "Healthcheck script not found -- skipping"
  fi
fi

echo ""

#===============================================================================
# SUMMARY
#===============================================================================
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo -e "${G}|                      Update Summary                          |${NC}"
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo ""

if [ -n "${NEW_VERSION:-}" ]; then
  echo -e "  Version: ${C}${NEW_VERSION}${NC}"
fi
echo -e "  From:    ${C}${LOCAL_HEAD:0:12}${NC}"
echo -e "  To:      ${C}${REMOTE_HEAD:0:12}${NC}"
echo ""

# Updated
if [ ${#UPDATED[@]} -gt 0 ]; then
  echo -e "  ${G}Updated:${NC}"
  for item in "${UPDATED[@]}"; do
    echo -e "    ${G}+${NC} $item"
  done
  echo ""
fi

# Manual action needed
if [ ${#MANUAL_ACTION[@]} -gt 0 ]; then
  echo -e "  ${Y}Needs manual action:${NC}"
  for item in "${MANUAL_ACTION[@]}"; do
    echo -e "    ${Y}!${NC} $item"
  done
  echo ""
fi

# Not touched
echo -e "  ${C}Not touched (client-specific):${NC}"
echo -e "    ${C}-${NC} .env, openclaw.json, IDENTITY.md, USER.md, SOUL.md, BUSINESS.md"
echo -e "    ${C}-${NC} BOOTSTRAP.md, workspace/.env, .op-env, entity-map.json"
echo -e "    ${C}-${NC} cron/jobs.json, Neo4j data, memory databases"
echo ""

echo -e "${G}+--------------------------------------------------------------+${NC}"
echo -e "  ${C}Log: $LOG_FILE${NC}"
echo -e "${G}+--------------------------------------------------------------+${NC}"
echo ""

log "=== Update complete: ${#UPDATED[@]} updated, ${#MANUAL_ACTION[@]} manual ==="
exit 0

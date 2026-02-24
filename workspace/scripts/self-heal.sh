#!/usr/bin/env bash
# self-heal.sh — Standalone self-heal script for OpenClaw infrastructure
# Called by the Self-Heal Watchdog cron job or run manually.
# Checks: Docker/Neo4j, gateway health, disk space, stale locks.
# Writes results to heal-log.json.
# Exit 0 = all healthy or healed. Exit 1 = something failed and could not be fixed.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
HOME_DIR="{{HOME}}"
HEALTH_DIR="${HOME_DIR}/.openclaw/workspace/health"
HEAL_LOG="${HEALTH_DIR}/heal-log.json"
HEAL_HISTORY="${HEALTH_DIR}/heal-history.log"
LOCK_DIR="${HOME_DIR}/.openclaw"
GATEWAY_URL="http://localhost:18789/health"
GATEWAY_TIMEOUT=5
NEO4J_CONTAINER="neo4j"
NEO4J_BOLT="bolt://localhost:7687"
NEO4J_AUTH="neo4j/openclaw-graph-2026"
DISK_THRESHOLD=90
LOCK_MAX_AGE_MIN=60
OVERALL_EXIT=0

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
mkdir -p "${HEALTH_DIR}"

# Initialize heal-log.json if missing or empty
if [[ ! -s "${HEAL_LOG}" ]]; then
    echo '[]' > "${HEAL_LOG}"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
timestamp() {
    date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log_heal() {
    local issue="$1"
    local diagnosis="$2"
    local action="$3"
    local result="$4"
    local verify="${5:-}"
    local duration_ms="${6:-0}"
    local ts
    ts="$(timestamp)"

    # Append to JSON log (using a temp file for atomic write)
    local tmp
    tmp="$(mktemp)"

    # Use python3 for reliable JSON manipulation
    python3 -c "
import json, sys
entry = {
    'timestamp': '${ts}',
    'issue': '${issue}',
    'diagnosis': '${diagnosis}',
    'action': '${action}',
    'result': '${result}',
    'verify': '${verify}',
    'duration_ms': ${duration_ms}
}
with open('${HEAL_LOG}', 'r') as f:
    data = json.load(f)
data.append(entry)
with open('${tmp}', 'w') as f:
    json.dump(data, f, indent=2)
"
    mv "${tmp}" "${HEAL_LOG}"

    # Append one-liner to history
    local dur_s
    dur_s=$(python3 -c "print(f'{${duration_ms}/1000:.1f}s')")
    echo "${ts} | ${issue} | ${action} | ${result} | ${dur_s}" >> "${HEAL_HISTORY}"
}

ms_since() {
    # Return milliseconds between now and a start time (epoch ms)
    local start="$1"
    local now
    now=$(python3 -c "import time; print(int(time.time()*1000))")
    echo $(( now - start ))
}

epoch_ms() {
    python3 -c "import time; print(int(time.time()*1000))"
}

# ---------------------------------------------------------------------------
# Check 1: Docker / Neo4j
# ---------------------------------------------------------------------------
check_neo4j() {
    echo "[CHECK] Neo4j container status..."
    local start
    start=$(epoch_ms)

    # Is Docker running?
    if ! docker info &>/dev/null; then
        echo "  [WARN] Docker daemon not reachable — cannot check Neo4j. Skipping."
        log_heal "docker_unreachable" "docker daemon not responding" "skip" "skipped" "cannot reach docker" 0
        # Don't fail overall — Docker Desktop might just not be open
        return 0
    fi

    local status
    status=$(docker inspect "${NEO4J_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")

    if [[ "${status}" == "running" ]]; then
        echo "  [OK] Neo4j container is running."
        return 0
    fi

    # Container exists but is not running
    if [[ "${status}" != "missing" ]]; then
        echo "  [HEAL] Neo4j container status: ${status}. Attempting restart..."
        docker start "${NEO4J_CONTAINER}" &>/dev/null
        echo "  [WAIT] Waiting 10 seconds for Neo4j to initialize..."
        sleep 10

        local new_status
        new_status=$(docker inspect "${NEO4J_CONTAINER}" --format '{{.State.Status}}' 2>/dev/null || echo "missing")
        local duration
        duration=$(ms_since "${start}")

        if [[ "${new_status}" == "running" ]]; then
            echo "  [OK] Neo4j restarted successfully."
            log_heal "neo4j_down" "container was ${status}" "docker start neo4j" "success" "container now running" "${duration}"
            return 0
        else
            echo "  [FAIL] Neo4j restart failed. Status: ${new_status}"
            log_heal "neo4j_down" "container was ${status}" "docker start neo4j" "failed" "status after restart: ${new_status}" "${duration}"
            OVERALL_EXIT=1
            return 1
        fi
    fi

    # Container does not exist at all
    echo "  [WARN] Neo4j container not found. It may need to be created manually."
    local duration
    duration=$(ms_since "${start}")
    log_heal "neo4j_missing" "container does not exist" "skip" "escalate" "manual creation needed" "${duration}"
    # Don't set OVERALL_EXIT=1 for missing container — it may be intentional
    return 0
}

# ---------------------------------------------------------------------------
# Check 2: Gateway health
# ---------------------------------------------------------------------------
check_gateway() {
    echo "[CHECK] Gateway health endpoint..."
    local start
    start=$(epoch_ms)

    local http_code
    http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time "${GATEWAY_TIMEOUT}" "${GATEWAY_URL}" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "200" ]]; then
        echo "  [OK] Gateway is healthy (HTTP 200)."
        return 0
    fi

    echo "  [WARN] Gateway returned HTTP ${http_code}."

    # Check if the node process is running at all
    local pid
    pid=$(lsof -ti :18789 2>/dev/null || echo "")

    if [[ -z "${pid}" ]]; then
        echo "  [HEAL] No process on port 18789. Attempting to restart via launchctl..."
        local uid
        uid=$(id -u)
        launchctl kickstart -k "gui/${uid}/com.openclaw.gateway" 2>/dev/null || true
        echo "  [WAIT] Waiting 5 seconds for gateway to start..."
        sleep 5

        http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time "${GATEWAY_TIMEOUT}" "${GATEWAY_URL}" 2>/dev/null || echo "000")
        local duration
        duration=$(ms_since "${start}")

        if [[ "${http_code}" == "200" ]]; then
            echo "  [OK] Gateway restarted successfully."
            log_heal "gateway_down" "no process on port 18789" "launchctl kickstart gateway" "success" "HTTP 200 after restart" "${duration}"
            return 0
        else
            echo "  [FAIL] Gateway restart failed. HTTP ${http_code} after restart."
            log_heal "gateway_down" "no process on port 18789" "launchctl kickstart gateway" "failed" "HTTP ${http_code} after restart" "${duration}"
            OVERALL_EXIT=1
            return 1
        fi
    else
        echo "  [INFO] Process ${pid} is on port 18789 but not responding healthily."
        echo "  [HEAL] Killing stale process and restarting..."
        kill "${pid}" 2>/dev/null || true
        sleep 2
        local uid
        uid=$(id -u)
        launchctl kickstart -k "gui/${uid}/com.openclaw.gateway" 2>/dev/null || true
        sleep 5

        http_code=$(curl -sf -o /dev/null -w "%{http_code}" --max-time "${GATEWAY_TIMEOUT}" "${GATEWAY_URL}" 2>/dev/null || echo "000")
        local duration
        duration=$(ms_since "${start}")

        if [[ "${http_code}" == "200" ]]; then
            echo "  [OK] Gateway recovered after killing stale process."
            log_heal "gateway_unhealthy" "stale process on port 18789 (pid ${pid})" "kill + restart" "success" "HTTP 200" "${duration}"
            return 0
        else
            echo "  [FAIL] Gateway still unhealthy after kill + restart."
            log_heal "gateway_unhealthy" "stale process on port 18789 (pid ${pid})" "kill + restart" "failed" "HTTP ${http_code}" "${duration}"
            OVERALL_EXIT=1
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# Check 3: Disk space
# ---------------------------------------------------------------------------
check_disk() {
    echo "[CHECK] Disk space..."
    local start
    start=$(epoch_ms)

    local usage_pct
    usage_pct=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')

    if [[ "${usage_pct}" -lt "${DISK_THRESHOLD}" ]]; then
        echo "  [OK] Disk usage at ${usage_pct}% (threshold: ${DISK_THRESHOLD}%)."
        return 0
    fi

    echo "  [WARN] Disk usage at ${usage_pct}% (>= ${DISK_THRESHOLD}%). Attempting cleanup..."

    local freed=0

    # Step 1: Clear compressed log files
    local log_count
    log_count=$(find /var/log "${HOME_DIR}/.openclaw" -name "*.log.gz" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${log_count}" -gt 0 ]]; then
        echo "  [HEAL] Removing ${log_count} compressed log files..."
        find /var/log "${HOME_DIR}/.openclaw" -name "*.log.gz" -type f -delete 2>/dev/null || true
        freed=1
    fi

    # Step 2: Clear old session files (>30 days)
    local session_count
    session_count=$(find "${HOME_DIR}/.openclaw/agents" -name "*.jsonl" -type f -mtime +30 2>/dev/null | wc -l | tr -d ' ')
    if [[ "${session_count}" -gt 0 ]]; then
        echo "  [HEAL] Removing ${session_count} session files older than 30 days..."
        find "${HOME_DIR}/.openclaw/agents" -name "*.jsonl" -type f -mtime +30 -delete 2>/dev/null || true
        freed=1
    fi

    # Step 3: Docker prune
    if docker info &>/dev/null; then
        echo "  [HEAL] Running docker system prune..."
        docker system prune -f &>/dev/null || true
        freed=1
    fi

    # Re-check
    local new_usage
    new_usage=$(df -h / | awk 'NR==2 {gsub(/%/,""); print $5}')
    local duration
    duration=$(ms_since "${start}")

    if [[ "${new_usage}" -lt 85 ]]; then
        echo "  [OK] Disk usage reduced to ${new_usage}% (target: <85%)."
        log_heal "disk_high" "usage was ${usage_pct}%" "cleanup (logs, sessions, docker prune)" "success" "usage now ${new_usage}%" "${duration}"
        return 0
    else
        echo "  [WARN] Disk usage still at ${new_usage}% after cleanup (target: <85%). Escalation needed."
        log_heal "disk_high" "usage was ${usage_pct}%" "cleanup (logs, sessions, docker prune)" "partial" "usage now ${new_usage}%, still above 85%" "${duration}"
        if [[ "${new_usage}" -ge "${DISK_THRESHOLD}" ]]; then
            OVERALL_EXIT=1
        fi
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Check 4: Stale lock files
# ---------------------------------------------------------------------------
check_locks() {
    echo "[CHECK] Stale lock files..."
    local start
    start=$(epoch_ms)

    # Find lock files older than LOCK_MAX_AGE_MIN minutes
    local stale_locks
    stale_locks=$(find "${LOCK_DIR}" -name "*.lock" -type f -mmin +"${LOCK_MAX_AGE_MIN}" 2>/dev/null || true)

    if [[ -z "${stale_locks}" ]]; then
        echo "  [OK] No stale lock files found."
        return 0
    fi

    local count
    count=$(echo "${stale_locks}" | wc -l | tr -d ' ')
    echo "  [WARN] Found ${count} stale lock file(s) older than ${LOCK_MAX_AGE_MIN} minutes."

    local removed=0
    local failed=0

    while IFS= read -r lockfile; do
        [[ -z "${lockfile}" ]] && continue

        # Try to read the PID from the lock file (if it contains one)
        local lock_pid
        lock_pid=$(head -1 "${lockfile}" 2>/dev/null | grep -oE '^[0-9]+$' || echo "")

        if [[ -n "${lock_pid}" ]] && kill -0 "${lock_pid}" 2>/dev/null; then
            echo "  [SKIP] ${lockfile} — owning PID ${lock_pid} is still alive."
            continue
        fi

        echo "  [HEAL] Removing stale lock: ${lockfile}"
        if rm -f "${lockfile}" 2>/dev/null; then
            removed=$((removed + 1))
        else
            failed=$((failed + 1))
        fi
    done <<< "${stale_locks}"

    local duration
    duration=$(ms_since "${start}")

    if [[ "${failed}" -eq 0 ]]; then
        echo "  [OK] Removed ${removed} stale lock file(s)."
        log_heal "stale_locks" "found ${count} lock files older than ${LOCK_MAX_AGE_MIN}min" "removed stale locks" "success" "${removed} removed, ${failed} failed" "${duration}"
        return 0
    else
        echo "  [WARN] Removed ${removed}, failed to remove ${failed} lock file(s)."
        log_heal "stale_locks" "found ${count} lock files older than ${LOCK_MAX_AGE_MIN}min" "removed stale locks" "partial" "${removed} removed, ${failed} failed" "${duration}"
        OVERALL_EXIT=1
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo "============================================"
    echo "  OpenClaw Self-Heal — $(timestamp)"
    echo "============================================"
    echo ""

    check_neo4j || true
    echo ""
    check_gateway || true
    echo ""
    check_disk || true
    echo ""
    check_locks || true
    echo ""

    echo "============================================"
    if [[ "${OVERALL_EXIT}" -eq 0 ]]; then
        echo "  RESULT: All checks passed or healed."
    else
        echo "  RESULT: One or more issues could not be resolved."
        echo "  Check ${HEAL_LOG} for details."
    fi
    echo "============================================"

    exit "${OVERALL_EXIT}"
}

main "$@"

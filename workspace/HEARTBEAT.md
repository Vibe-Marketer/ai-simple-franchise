# HEARTBEAT.md

## Self-Heal-First Protocol

Before checking messages, emails, or projects, every heartbeat cycle MUST begin with system health. A broken agent cannot help anyone.

### Priority Order: DETECT -> DIAGNOSE -> FIX -> VERIFY -> LOG -> ESCALATE

#### 1. DETECT — Identify the Issue

Scan for these failure classes on every heartbeat:

| Check | Method | Healthy Signal |
|-------|--------|----------------|
| Neo4j | `docker inspect neo4j --format '{{.State.Status}}'` | "running" |
| Gateway | `curl -sf http://localhost:18789/health` | HTTP 200 |
| Disk space | `df -h /` | <90% used |
| Stale locks | Find `*.lock` files in `{{HOME}}/.openclaw/` older than 60 min | None found |
| Cron health | Check last 3 runs of each cron in session logs | <3 consecutive errors |
| API errors | Check recent logs for 401/403/429 responses | None in last hour |

#### 2. DIAGNOSE — Determine Root Cause

For each detected issue, identify the root cause before acting:

- **Neo4j down** — Container stopped? OOM-killed? Docker daemon dead? Check `docker ps -a` and `docker logs neo4j --tail 20`.
- **Gateway unreachable** — Node process crashed? Port conflict? Check `lsof -i :18789` and `ps aux | grep openclaw`.
- **Disk full** — Old logs? Docker images? Large session files? Check `du -sh {{HOME}}/.openclaw/agents/*/sessions/ {{HOME}}/.openclaw/memory/ /var/log/` for the biggest offenders.
- **Stale locks** — Process crashed while holding lock? Verify the owning PID is no longer running.
- **Cron failures** — Agent unresponsive? Skill broken? Dependency missing? Read the last 3 session logs for that cron.
- **API errors** — Rate limited (429)? Token expired (401)? Service outage (5xx)? Check response headers and status.

#### 3. FIX — Attempt Automatic Repair

Execute the appropriate fix. Each fix has ONE retry. If it fails twice, move to ESCALATE.

| Issue | Fix Action | Timeout |
|-------|------------|---------|
| Neo4j container stopped | `docker start neo4j` then wait 10s, verify with health check | 30s |
| Neo4j container missing | `docker run -d --name neo4j --restart unless-stopped -p 7474:7474 -p 7687:7687 -e NEO4J_AUTH=neo4j/openclaw-graph-2026 -v neo4j_data:/data neo4j:5` | 60s |
| Gateway unreachable, node dead | `launchctl kickstart -k gui/$(id -u)/com.openclaw.gateway` | 15s |
| Gateway unreachable, port stuck | Kill orphaned process on :18789, then restart LaunchAgent | 20s |
| Disk >90% | Clear in order: `*.log.gz` files, session files >30 days, `docker system prune -f` | 60s |
| Stale locks (>60 min) | Remove lock files after confirming owning PID is dead | 5s |
| Cron consecutive errors >3 | Log the issue, verify agent is responsive via health endpoint, restart if needed | 30s |
| API rate limit (429) | Exponential backoff: wait 30s, then 60s, then 120s. If persistent, switch to fallback model in request | 5m |
| API auth error (401/403) | Do NOT auto-rotate. Log and escalate immediately | 0s |

#### 4. VERIFY — Confirm the Fix Worked

After every fix attempt, re-run the original detection check. The issue must be fully resolved, not just appear resolved:

- Neo4j: run a test Cypher query (`RETURN 1`), not just check container status
- Gateway: hit `/health` AND verify a simple API call succeeds
- Disk: confirm usage dropped below 85% (not just below 90%)
- Locks: confirm the lock file is gone AND no new one appeared
- Crons: trigger a test run of the failing cron and confirm success

#### 5. LOG — Record Everything

Write every heal action to `{{HOME}}/.openclaw/workspace/health/heal-log.json`:

```json
{
  "timestamp": "2026-02-23T14:30:00Z",
  "issue": "neo4j_down",
  "diagnosis": "container stopped, exit code 137 (OOM)",
  "action": "docker start neo4j",
  "result": "success",
  "verify": "RETURN 1 query succeeded",
  "duration_ms": 12400
}
```

Also append a one-line summary to `{{HOME}}/.openclaw/workspace/health/heal-history.log` for quick scanning:

```
2026-02-23T14:30:00Z | neo4j_down | docker start neo4j | success | 12.4s
```

#### 6. ESCALATE — Only When Self-Heal FAILED

Escalate to Andrew (via primary Telegram channel) ONLY when:

- A fix was attempted and FAILED after all retries
- The issue is in the "What NOT to self-heal" list
- An issue has recurred 3+ times in 24 hours (even if individually fixed — pattern indicates deeper problem)
- Disk space cannot be recovered below 85% after cleanup

Escalation message format:
```
[HEAL-FAIL] {issue} — Attempted {action}, result: {error}. Manual intervention needed. Details in heal-log.json.
```

### What NOT to Self-Heal

These actions are NEVER performed automatically. Always escalate:

- **Never auto-rotate API keys or tokens** — Security decisions require human approval
- **Never delete user data** — Session files with active conversations, memory vectors, graph nodes with user content
- **Never modify openclaw.json** — Configuration changes can cascade unpredictably
- **Never restart Docker daemon** — Could affect other containers/services
- **Never change Neo4j password** — Would break all existing connections
- **Never modify LaunchAgent plist files** — Could break boot-time service recovery
- **Never force-kill processes you did not start** — Only kill processes that are clearly orphaned from your own operations

### Self-Heal Script

A standalone script at `workspace/scripts/self-heal.sh` performs the same checks and can be called by the Self-Heal Watchdog cron or run manually. It writes to the same heal-log.json.

---

## Priority Checks (rotate through, 2-4x/day)

Only proceed to these AFTER self-heal checks pass (or issues are logged/escalated):

1. **Unanswered messages?** Check iMessage (BlueBubbles), WhatsApp, Telegram. Reply if needed.
2. **Urgent emails?** Check via Composio Gmail integration. Alert user only if action is required.
3. **Calendar events <24h?** Check via Composio Google Calendar. Prep or remind if <2h away.
4. **Project blockers?** Check active repos for CI failures, open PRs, stale issues.
5. **Cron health?** Any errors in recent cron runs? Fix broken ones autonomously.

## Do Without Asking (Tier 0)

- Run self-heal checks before anything else
- Fix broken integrations, report after
- Update memory files from recent context
- Check git status on active repos
- Curate MEMORY.md if 3+ days since last review
- Read through recent daily log files and extract insights

## Reach Out When

- Self-heal FAILED and manual intervention is needed
- Important email or message arrived that needs attention
- Calendar event coming up (<2h away)
- Found an opportunity or risk worth flagging
- Fixed something significant (brief report)
- Been >8h since last communication with user

## Stay Quiet (HEARTBEAT_OK)

- Late night (23:00-08:00 in user's timezone) unless urgent
- Nothing new since last check
- User is clearly in deep work / focused session
- Last check was <30 minutes ago
- Casual banter in group chats that does not need your input
- Self-heal succeeded — log it, do not notify

## State Tracking

Track check timestamps in `memory/heartbeat-state.json`:

```json
{
  "lastChecks": {
    "selfHeal": null,
    "messages": null,
    "email": null,
    "calendar": null,
    "projects": null,
    "crons": null
  },
  "lastUserContact": null,
  "healStats": {
    "totalHeals": 0,
    "lastHealTimestamp": null,
    "issuesLast24h": []
  }
}
```

## Memory Maintenance (During Heartbeats)

Every few days, use a heartbeat cycle to:

1. Read through recent `memory/YYYY-MM-DD.md` files
2. Identify significant events, lessons, or insights worth keeping long-term
3. Update `MEMORY.md` with distilled learnings
4. Remove outdated info from MEMORY.md that is no longer relevant

Daily files are raw notes. MEMORY.md is curated wisdom.

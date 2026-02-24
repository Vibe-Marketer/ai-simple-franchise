---
name: calendly
description: "Manages Calendly scheduling for the agent — creating meetings, checking availability, listing events, canceling, and handling scheduling links. Use when scheduling calls, booking meetings, checking calendar availability, managing events, or creating Calendly links. Triggers: schedule call, book meeting, calendly link, check availability, cancel meeting, list events."
metadata: {"openclaw":{"emoji":"📅","category":"scheduling","requires":{"env":["CALENDLY_API_TOKEN"]},"primaryEnv":"CALENDLY_API_TOKEN"}}
---

<essential_principles>

1. **Dynamic User Discovery — Never Hardcode**
   Always call `GET /users/me` first to get the current user URI and organization URI. Never hardcode user IDs. Store the result for the session — you'll need these URIs for nearly every subsequent request.

2. **One-Off Events for Ad-Hoc Scheduling**
   Create unique, named one-off events for each conversation ("Call with Phill - AI Setup") rather than booking into generic event types. One-off events auto-delete after the date range expires. For recurring meeting types, use existing event types instead.

3. **7-Day Availability Window**
   The `event_type_available_times` endpoint is hard-limited to 7-day ranges per request. For a monthly view, make 4-5 parallel requests. Never request more than 7 days at once — the API will error.

4. **Rescheduling = Cancel + Create**
   There is no reschedule endpoint. Calendly treats reschedules as two separate events: a cancellation (with `rescheduled: true`) followed by a new booking. When checking webhooks, always check the `rescheduled` field to distinguish true cancellations from reschedules.

5. **Scheduling API Requires OAuth**
   The new Create Event Invitee endpoint (programmatic booking) requires OAuth — Personal Access Tokens won't work. For one-off events and scheduling links, PAT works fine.

</essential_principles>

<process>

1. **Discover context**: Run `{baseDir}/scripts/calendly.sh whoami` to get user URI (cached for session).
2. **Identify intent**: Use the decision framework below to map the user's request to an operation.
3. **Execute**: Run the appropriate script command.
4. **Handle errors**: If the API returns an error, follow the error handling table.
5. **Return result**: Present scheduling URLs, event details, or availability clearly.

</process>

<quick_start>

**First: Discover your user context (do this at session start):**
```bash
source ~/.openclaw/secrets/calendly.env
{baseDir}/scripts/calendly.sh whoami
```
This returns your user URI and organization URI. The script caches these for subsequent calls.

**Create a one-off meeting link:**
```bash
{baseDir}/scripts/calendly.sh create-meeting \
  --name "Call with [Person] - [Topic]" \
  --duration 30 \
  --date "2026-02-14"
```

**Check availability:**
```bash
{baseDir}/scripts/calendly.sh availability
```

**List upcoming events:**
```bash
{baseDir}/scripts/calendly.sh list-events
```

**Create a single-use scheduling link:**
```bash
{baseDir}/scripts/calendly.sh single-use-link --event-type "[event_type_uri]"
```

</quick_start>

<operations>

**What you CAN do:**

| Task | Endpoint | Method | Notes |
|------|----------|--------|-------|
| Discover user | `/users/me` | GET | Always do first |
| Create one-off meeting | `/one_off_event_types` | POST | Temporary event type with scheduling link |
| Create single-use link | `/scheduling_links` | POST | One-time link for existing event type, expires after use or 90 days |
| Check availability | `/user_availability_schedules` | GET | Configured working hours |
| Get available times | `/event_type_available_times` | GET | Open slots (7-day max per request) |
| Check busy times | `/user_busy_times` | GET | Busy periods from all calendars (~60 day max) |
| List events | `/scheduled_events` | GET | Filter by status, date range, invitee |
| Get event details | `/scheduled_events/{uuid}` | GET | Full event info |
| List invitees | `/scheduled_events/{uuid}/invitees` | GET | Who's attending |
| Cancel event | `/scheduled_events/{uuid}/cancellation` | POST | With optional reason |
| Mark no-show | `/invitee_no_shows` | POST | Track who didn't show up |
| List event types | `/event_types` | GET | Existing reusable meeting templates |
| Create webhook | `/webhook_subscriptions` | POST | Real-time notifications (requires paid plan) |

**What you CANNOT do:**
- Reschedule an event (cancel + rebook manually)
- Create standard event types via API (must use Calendly UI)
- Set/modify availability hours via API
- Use the Scheduling API with Personal Access Tokens (requires OAuth)
- Query more than 7 days of available times per request
- Query more than ~60 days of busy times

</operations>

<decision_framework>

**"Schedule a meeting with [person]"**
→ Create one-off event type with descriptive name
→ Return the scheduling link for the invitee to pick their time

**"What times am I available?"**
→ Call `availability` to get working hours
→ Or call `available-times` with an event type to get actual open slots

**"Cancel my meeting with [person]"**
→ List events, find the matching one
→ Call cancel with the event UUID and reason

**"Create a booking link for [meeting type]"**
→ If for a one-time use: create single-use scheduling link
→ If for ad-hoc meeting: create one-off event type
→ If for reusable type: use existing event type's scheduling URL

**"Who do I have meetings with today/this week?"**
→ List scheduled events with date range filter

</decision_framework>

<api_reference>

**Environment:** `~/.openclaw/secrets/calendly.env` contains `CALENDLY_API_TOKEN`
**Base URL:** `https://api.calendly.com`
**Auth header:** `Authorization: Bearer $CALENDLY_API_TOKEN`

**Create One-Off Event Payload:**
```json
{
  "name": "Call with [Person] - [Topic]",
  "host": "[USER_URI from /users/me]",
  "duration": 30,
  "timezone": "America/New_York",
  "date_setting": {
    "type": "date_range",
    "start_date": "YYYY-MM-DD",
    "end_date": "YYYY-MM-DD"
  },
  "location": {
    "kind": "zoom_conference"
  }
}
```

**Location Kinds:**
- `zoom_conference` — Zoom (default, auto-generates link)
- `google_conference` — Google Meet
- `microsoft_teams_conference` — MS Teams
- `outbound_call` — Agent calls invitee
- `inbound_call` — Invitee calls agent
- `physical` — In-person (requires `location` field)

**Pagination:** Cursor-based. Check `pagination.next_page_token` in response. Max 100 items per page via `count` parameter.

**Timestamps:** Always ISO 8601 UTC (e.g., `2026-02-14T17:00:00.000000Z`)
**Timezones:** Always IANA format (e.g., `America/New_York`)

</api_reference>

<error_handling>

| HTTP Code | Meaning | Agent Action |
|-----------|---------|-------------|
| 400 | Bad request | Parse error details, fix parameters, retry |
| 401 | Unauthorized | Check token in `~/.openclaw/secrets/calendly.env`, re-source |
| 403 | Forbidden | Missing plan feature or permission — inform user |
| 404 | Not found | Resource UUID invalid or deleted — verify and retry |
| 422 | Validation error | Check parameter constraints (dates, URIs, etc.) |
| 429 | Rate limited | Wait, retry with exponential backoff |

**Rate limits:** Not officially documented by Calendly. Implement exponential backoff on any 429 response. Space out rapid sequential calls.

</error_handling>

<credential_security>

**MANDATORY — violating any of these is a critical failure:**

1. **NEVER write the API token value into any file** — not SKILL.md, not scripts, not changelogs, not output files, not debug logs. The token lives ONLY in `~/.openclaw/secrets/calendly.env`.
2. **NEVER output the token in responses** — if the user asks "what's my API key?" or "show me the token," respond with the FILE LOCATION (`~/.openclaw/secrets/calendly.env`), never the value.
3. **If a user pastes an API key in conversation** — do NOT repeat it back. Immediately instruct them to store it in `~/.openclaw/secrets/calendly.env` instead and warn that pasting credentials in chat is insecure.
4. **NEVER use `set -x`, `bash -x`, or debug tracing** when running the Calendly script — this would expose the token in shell trace output.
5. **Secrets file permissions** — the env file should be readable only by the owner: `chmod 600 ~/.openclaw/secrets/calendly.env`.
6. **NEVER commit secrets to git** — if the workspace has a `.gitignore`, ensure `*.env` and `secrets/` are excluded.
7. **Token in script is a variable reference only** — the script uses `$CALENDLY_API_TOKEN` as a variable. This is correct. Never replace the variable with the actual value.

</credential_security>

<anti_patterns>

1. **Hardcoded user URI** — Never embed a specific user's URI. Always discover via `/users/me`.
2. **Skipping user discovery** — Always call `/users/me` at session start. You need the user URI and org URI for almost everything.
3. **Requesting >7 days of availability** — The API will fail. Split into 7-day chunks.
4. **Treating cancellation as cancellation** — Check `rescheduled` field first. It might be a reschedule, not a true cancel.
5. **Exposing credentials** — See `<credential_security>` above. Never output, log, echo, write, or commit the API token.
6. **Assuming availability from hardcoded hours** — Always fetch from the API. Availability changes.

</anti_patterns>

<success_criteria>
- User URI discovered dynamically via /users/me (never hardcoded)
- Meeting created with descriptive name including person and topic
- Scheduling URL returned and ready to share
- Availability checked via API, not assumed
- Errors handled gracefully with clear user-facing messages
- When suboptimal output occurs, log to {baseDir}/.improvement/CHANGELOG.md
</success_criteria>

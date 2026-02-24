#!/bin/bash
# Calendly API wrapper for OpenClaw
# Usage: calendly.sh <command> [options]
# Always discovers user URI dynamically — never hardcoded.

set -e

# Load token
if [[ -f ~/.openclaw/secrets/calendly.env ]]; then
  source ~/.openclaw/secrets/calendly.env
fi

if [[ -z "$CALENDLY_API_TOKEN" ]]; then
  echo "Error: CALENDLY_API_TOKEN not set. Add it to ~/.openclaw/secrets/calendly.env" >&2
  exit 1
fi

BASE_URL="https://api.calendly.com"

# Cache file for user context (avoids repeated /users/me calls)
CACHE_DIR="${TMPDIR:-/tmp}/calendly-cache"
mkdir -p "$CACHE_DIR"
CACHE_FILE="$CACHE_DIR/user-context.json"

auth_header() {
  echo "Authorization: Bearer $CALENDLY_API_TOKEN"
}

# API call wrapper with error handling
api_call() {
  local method="$1"
  local endpoint="$2"
  local data="$3"
  local response

  if [[ "$method" == "GET" ]]; then
    response=$(curl -s -w "\n%{http_code}" -H "$(auth_header)" -H "Content-Type: application/json" "$BASE_URL$endpoint")
  else
    response=$(curl -s -w "\n%{http_code}" -X "$method" -H "$(auth_header)" -H "Content-Type: application/json" -d "$data" "$BASE_URL$endpoint")
  fi

  local http_code=$(echo "$response" | tail -1)
  local body=$(echo "$response" | sed '$d')

  if [[ "$http_code" -ge 400 ]]; then
    echo "Error: HTTP $http_code" >&2
    case "$http_code" in
      401) echo "Unauthorized — check CALENDLY_API_TOKEN in ~/.openclaw/secrets/calendly.env" >&2 ;;
      403) echo "Forbidden — this feature may require a paid Calendly plan" >&2 ;;
      404) echo "Not found — resource may have been deleted or UUID is invalid" >&2 ;;
      422) echo "Validation error — check parameter formats (dates, URIs)" >&2 ;;
      429) echo "Rate limited — wait and retry" >&2 ;;
    esac
    echo "$body" | jq '.message // .title // .' 2>/dev/null >&2
    return 1
  fi

  echo "$body"
}

# Discover user URI dynamically (cached per session)
get_user_uri() {
  # Use cache if fresh (less than 1 hour old)
  if [[ -f "$CACHE_FILE" ]] && [[ $(find "$CACHE_FILE" -mmin -60 2>/dev/null) ]]; then
    jq -r '.uri' "$CACHE_FILE"
    return
  fi

  local user_data
  user_data=$(api_call GET "/users/me") || return 1
  echo "$user_data" | jq '.resource' > "$CACHE_FILE"
  echo "$user_data" | jq -r '.resource.uri'
}

get_org_uri() {
  if [[ -f "$CACHE_FILE" ]]; then
    jq -r '.current_organization' "$CACHE_FILE"
    return
  fi
  get_user_uri > /dev/null
  jq -r '.current_organization' "$CACHE_FILE"
}

# Get current user info
whoami() {
  local user_data
  user_data=$(api_call GET "/users/me") || return 1
  echo "$user_data" | jq '.resource' | tee "$CACHE_FILE"
}

# Create a one-off meeting
create_meeting() {
  local name=""
  local duration=30
  local date=""
  local end_date=""
  local location="zoom_conference"
  local timezone="America/New_York"

  while [[ $# -gt 0 ]]; do
    case $1 in
      --name) name="$2"; shift 2 ;;
      --duration) duration="$2"; shift 2 ;;
      --date) date="$2"; shift 2 ;;
      --end-date) end_date="$2"; shift 2 ;;
      --location) location="$2"; shift 2 ;;
      --timezone) timezone="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$name" ]]; then
    echo "Error: --name required (e.g., --name \"Call with Phill - AI Setup\")" >&2
    exit 1
  fi

  if [[ -z "$date" ]]; then
    date=$(date +%Y-%m-%d)
  fi

  if [[ -z "$end_date" ]]; then
    end_date="$date"
  fi

  local user_uri
  user_uri=$(get_user_uri) || { echo "Error: Could not discover user URI" >&2; exit 1; }

  api_call POST "/one_off_event_types" '{
    "name": "'"$name"'",
    "host": "'"$user_uri"'",
    "duration": '"$duration"',
    "timezone": "'"$timezone"'",
    "date_setting": {
      "type": "date_range",
      "start_date": "'"$date"'",
      "end_date": "'"$end_date"'"
    },
    "location": {
      "kind": "'"$location"'"
    }
  }' | jq '{
    name: .resource.name,
    scheduling_url: .resource.scheduling_url,
    duration: .resource.duration,
    uri: .resource.uri,
    created: .resource.created_at
  }'
}

# Get user availability
availability() {
  local user_uri
  user_uri=$(get_user_uri) || return 1

  api_call GET "/user_availability_schedules?user=$user_uri" | \
    jq '.collection[] | {
      name: .name,
      timezone: .timezone,
      rules: [.rules[] | select(.intervals | length > 0) | {
        day: .wday,
        hours: .intervals
      }]
    }'
}

# Get available times for an event type (max 7-day window)
available_times() {
  local event_type_uri="$1"
  local start_time="${2:-$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)}"
  local end_time="${3:-$(date -u -v+7d +%Y-%m-%dT%H:%M:%S.000000Z 2>/dev/null || date -u -d '+7 days' +%Y-%m-%dT%H:%M:%S.000000Z)}"

  if [[ -z "$event_type_uri" ]]; then
    echo "Error: event_type_uri required as first argument" >&2
    echo "Usage: calendly.sh available-times <event_type_uri> [start_time] [end_time]" >&2
    echo "Note: Maximum 7-day range per request" >&2
    exit 1
  fi

  api_call GET "/event_type_available_times?event_type=$event_type_uri&start_time=$start_time&end_time=$end_time" | \
    jq '.collection[] | {start_time: .start_time}'
}

# Get user busy times
busy_times() {
  local user_uri
  user_uri=$(get_user_uri) || return 1

  local start_time="${1:-$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)}"
  local end_time="${2:-$(date -u -v+7d +%Y-%m-%dT%H:%M:%S.000000Z 2>/dev/null || date -u -d '+7 days' +%Y-%m-%dT%H:%M:%S.000000Z)}"

  api_call GET "/user_busy_times?user=$user_uri&start_time=$start_time&end_time=$end_time" | \
    jq '.collection[] | {
      type: .type,
      start: .start_time,
      end: .end_time
    }'
}

# List scheduled events
list_events() {
  local user_uri
  user_uri=$(get_user_uri) || return 1

  local status="${1:-active}"
  local min_start="${2:-$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)}"

  api_call GET "/scheduled_events?user=$user_uri&status=$status&min_start_time=$min_start&count=10" | \
    jq '.collection[] | {
      name: .name,
      start: .start_time,
      end: .end_time,
      status: .status,
      location: .location,
      uri: .uri
    }'
}

# Cancel an event
cancel_event() {
  local event_uri="$1"
  local reason="${2:-Cancelled by agent}"

  if [[ -z "$event_uri" ]]; then
    echo "Error: event_uri required as first argument" >&2
    exit 1
  fi

  # Extract UUID from URI
  local uuid=$(echo "$event_uri" | grep -oE '[a-f0-9-]{36}')

  api_call POST "/scheduled_events/$uuid/cancellation" '{
    "reason": "'"$reason"'"
  }'
}

# List invitees for an event
list_invitees() {
  local event_uri="$1"

  if [[ -z "$event_uri" ]]; then
    echo "Error: event_uri required" >&2
    exit 1
  fi

  local uuid=$(echo "$event_uri" | grep -oE '[a-f0-9-]{36}')

  api_call GET "/scheduled_events/$uuid/invitees" | \
    jq '.collection[] | {
      name: .name,
      email: .email,
      status: .status,
      created: .created_at
    }'
}

# Create single-use scheduling link
single_use_link() {
  local event_type_uri=""
  local max_event_count=1

  while [[ $# -gt 0 ]]; do
    case $1 in
      --event-type) event_type_uri="$2"; shift 2 ;;
      --max-uses) max_event_count="$2"; shift 2 ;;
      *) shift ;;
    esac
  done

  if [[ -z "$event_type_uri" ]]; then
    echo "Error: --event-type required" >&2
    echo "Use 'calendly.sh list-types' to find event type URIs" >&2
    exit 1
  fi

  local owner_uri
  owner_uri=$(get_user_uri) || return 1

  api_call POST "/scheduling_links" '{
    "max_event_count": '"$max_event_count"',
    "owner": "'"$event_type_uri"'",
    "owner_type": "EventType"
  }' | jq '{
    booking_url: .resource.booking_url,
    owner: .resource.owner,
    max_event_count: .resource.max_event_count
  }'
}

# List event types
list_event_types() {
  local user_uri
  user_uri=$(get_user_uri) || return 1

  local active="${1:-true}"

  api_call GET "/event_types?user=$user_uri&active=$active" | \
    jq '.collection[] | {
      name: .name,
      duration: .duration,
      scheduling_url: .scheduling_url,
      uri: .uri,
      active: .active
    }'
}

# Mark invitee as no-show
mark_no_show() {
  local invitee_uri="$1"

  if [[ -z "$invitee_uri" ]]; then
    echo "Error: invitee_uri required" >&2
    exit 1
  fi

  api_call POST "/invitee_no_shows" '{
    "invitee": "'"$invitee_uri"'"
  }'
}

# Main command router
case "${1:-help}" in
  create-meeting|create)
    shift
    create_meeting "$@"
    ;;
  availability|avail)
    availability
    ;;
  available-times|times)
    shift
    available_times "$@"
    ;;
  busy-times|busy)
    shift
    busy_times "$@"
    ;;
  list-events|events)
    shift
    list_events "$@"
    ;;
  list-invitees|invitees)
    shift
    list_invitees "$@"
    ;;
  cancel)
    shift
    cancel_event "$@"
    ;;
  single-use-link|single-use)
    shift
    single_use_link "$@"
    ;;
  list-types|types)
    shift
    list_event_types "$@"
    ;;
  mark-no-show|no-show)
    shift
    mark_no_show "$@"
    ;;
  whoami|me)
    whoami
    ;;
  help|*)
    cat <<EOF
Calendly CLI for OpenClaw

Commands:
  whoami            Get current user info (always run first)
  create-meeting    Create a one-off meeting
    --name          Meeting name (required)
    --duration      Duration in minutes (default: 30)
    --date          Start date YYYY-MM-DD (default: today)
    --end-date      End date YYYY-MM-DD (default: same as start)
    --location      Location kind (default: zoom_conference)
    --timezone      Timezone (default: America/New_York)

  availability      Show user availability schedule
  available-times   Get available times for an event type (7-day max)
  busy-times        Get user busy times from all calendars
  list-events       List scheduled events (default: active, from now)
  list-invitees     List invitees for a specific event
  cancel            Cancel a scheduled event
  single-use-link   Create a single-use scheduling link
    --event-type    Event type URI (required)
    --max-uses      Max bookings (default: 1)
  list-types        List event types
  mark-no-show      Mark an invitee as no-show
  whoami            Get current user info

Examples:
  calendly.sh whoami
  calendly.sh create-meeting --name "Call with Phill" --date 2026-02-14
  calendly.sh availability
  calendly.sh list-events
  calendly.sh list-types
  calendly.sh single-use-link --event-type "https://api.calendly.com/event_types/..."
EOF
    ;;
esac

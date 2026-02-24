# Calendly Skill Changelog

## 2026-02-14 [fix] [audit]
- **What happened**: Comprehensive audit revealed the skill was severely limited — hardcoded user URI, only covered one-off meetings, empty references dir, no error handling, assumed availability hours
- **Root cause**: Skill was built from user knowledge without deep API research. Calendly has 43 endpoints; the skill used 6.
- **Fix applied**: Complete rewrite based on Calendly API v2 research (7+ sources):
  - Dynamic user discovery via `/users/me` (never hardcoded)
  - Added operations table covering 13 key endpoints (was 6)
  - Added decision framework (which endpoint for which user request)
  - Added 6 anti-patterns specific to Calendly
  - Added error handling table with agent actions per HTTP code
  - Added "What you CANNOT do" section (critical for agent behavior)
  - Script rewritten: `api_call()` wrapper with error handling, user URI caching, new commands (busy-times, single-use-link, list-invitees, mark-no-show, available-times)
  - Documented 7-day availability window limit, rescheduling behavior, OAuth requirements
- **Evidence**: API research found Calendly launched a Scheduling API in 2025, has 43 endpoints, and has specific gotchas (7-day window, rescheduling = cancel+create, OAuth-only for booking)
- **Impact**: Agent now has comprehensive Calendly knowledge: all operations, error handling, decision framework, anti-patterns, limitations

## 2026-02-14 [create] [initial]
- Created skill with one-off meeting creation
- Added Zoom conference as default location
- Implemented availability checking
- Added scripts for CLI access

### Known Limitations
- Cannot book a specific time slot FOR someone via PAT (requires OAuth + Scheduling API)
- Invitee must click link and choose their time (for PAT-based flow)
- One-off events auto-expire after date range
- No webhook management (requires paid plan)

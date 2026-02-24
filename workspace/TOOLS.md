# TOOLS.md - Tools Inventory

Skills define *how* tools work. This file tracks what is available on this installation and any environment-specific notes.

## Memory Tools (mem0 v2)

Persistent memory across sessions via semantic search and knowledge graph.

| Tool | Purpose |
|------|---------|
| `memory_search` | Semantic search across all stored memories. Use before asking the user anything factual. |
| `memory_store` | Extract and store facts from a conversation snippet. Auto-extracts key entities and relationships. |
| `memory_store_raw` | Store a raw text string as a memory without extraction. Use for verbatim notes. |
| `memory_list` | List all stored memories for a given user ID. |
| `memory_get` | Retrieve a specific memory by ID. |
| `memory_forget` | Delete a specific memory by ID. Use when information is outdated or incorrect. |
| `memory_update` | Update an existing memory's content by ID. |

**Backend:** SQLite vector store + Neo4j graph store. Gemini embeddings via OpenRouter. GPT-4o-mini for entity extraction via OpenRouter.

## Composio Tools (OAuth Integrations)

Connect and interact with third-party services via OAuth.

| Tool | Purpose |
|------|---------|
| `composio_connect` | Generate an OAuth link for a user to connect a service (Gmail, Calendar, Slack, etc.). |
| `composio_execute` | Execute an action on a connected service (send email, create event, post message, etc.). |
| `composio_list_actions` | List available actions for a connected service/toolkit. |
| `composio_connections_status` | Check which services are connected for a given entity. |

**Configured toolkits:** gmail, googlecalendar, slack, notion, github. Additional toolkits can be added in openclaw.json.

## Messaging Channels

| Channel | Tool/Skill | Notes |
|---------|------------|-------|
| iMessage | BlueBubbles skill (`bluebubbles`) | Requires BlueBubbles server running locally. Plain text only -- no markdown. |
| WhatsApp | wacli skill (`wacli`) | Linked via QR code. Plain text only. |
| Telegram | Telegram plugin | Bot token configured in openclaw.json. Supports reactions, media up to 50MB. |

**Formatting rules across all chat channels:**
- No markdown in DMs (no bold, italics, headers, code blocks)
- No markdown tables in WhatsApp/Telegram -- use bullet lists
- Wrap Discord links in `<>` to suppress embeds
- Keep messages concise -- first sentence is the point

## GitHub

- **Tool:** `gh` CLI (authenticated via keyring)
- **Capabilities:** Repos, PRs, issues, gists, workflows, org access
- **Usage:** Prefer `gh` over raw git for GitHub operations

## Model Cost Rules

Use the cheapest model that can handle the task:

| Tier | Models | Use For | Approx Cost |
|------|--------|---------|-------------|
| Premium | claude-opus-4-5 | Complex architecture, strategy, critical code | $$$$ |
| Standard | claude-sonnet-4-5 | Most tasks, content, business logic, code | $$ |
| Fast | claude-haiku-4-5, kimi-k2.5 | Quick responses, classification, research | $ |
| Minimal | gemini-flash-lite, gpt-4o-mini | Heartbeats, crons, simple checks | cents |

**Rules:**
- Never use Opus for heartbeats or crons
- Default to Sonnet unless the task clearly needs more or less
- Sub-agents should use Haiku unless the task demands Sonnet
- Batch cheap periodic checks into heartbeats rather than separate cron jobs

## Local Notes

Add environment-specific notes below as you discover them (camera names, SSH hosts, preferred voices, device nicknames, etc.).

---

*This file is your cheat sheet. Update it whenever you learn something about the local setup.*

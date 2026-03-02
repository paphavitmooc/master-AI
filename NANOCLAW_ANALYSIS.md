# NanoClaw Fork Analysis & Architecture

> **Question:** Can we fork `qwibitai/nanoclaw` and enhance it to become the Master Agent?
> **Verdict:** Yes — strong foundation. ~60% of our plan is already built. Key gap is the web interface.

**Source repo:** https://github.com/qwibitai/nanoclaw
**License:** MIT (fork freely, commercial use allowed)
**Activity:** Very high — multiple commits per day, v1.1.6, 17k+ stars, 2.7k forks
**Analyzed:** 2026-03-02

---

## Decisions (Locked In)

| # | Decision | Choice | Rationale |
|---|---|---|---|
| 1 | **Fork destination** | Same repo — `paphavitmooc/master-AI` | Single place to track everything |
| 2 | **Web server** | **Hono** inside the Node.js process | TypeScript-native, single process, no inter-process IPC needed |
| 3 | **Channels** | **WhatsApp + Telegram + Web** — with strict channel isolation | "In from WhatsApp → out to WhatsApp only", same for Telegram and Web |
| 4 | **Agent name / soul** | Deferred | Assigned later; soul doc written before Phase 3 begins |

---

## What NanoClaw Already Provides

| Requirement | Status | Notes |
|---|---|---|
| Claude SDK agent loop | ✅ Built | `@anthropic-ai/claude-agent-sdk` inside Docker containers |
| Multi-agent / subagents | ✅ Built | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, MCP-based IPC |
| Persistent session memory | ✅ Built | `sessionId` in SQLite + `CLAUDE_MEMORY.md` per group |
| Task scheduler | ✅ Built | cron / interval / once, SQLite-backed, timezone-aware |
| Host ↔ container IPC | ✅ Built | Atomic file writes to `/workspace/ipc/`, host-side poller |
| Container-based isolation | ✅ Built | Docker `--rm`, non-root, read-only project mount |
| Secret handling | ✅ Excellent | Secrets via stdin only, deleted immediately after read |
| Mount security | ✅ Excellent | External allowlist, `.ssh`/`.env`/etc. always blocked |
| Per-agent customization | ✅ Built | Per-group agent-runner source copy, recompiled on start |
| Skills engine | ✅ Built | Structured `skills-engine/` for adding features without core changes |
| Audit / logging | ✅ Partial | `pino` structured logging; no dedicated audit trail table yet |
| VPS systemd service | ✅ Partial | macOS launchd plist exists; Ubuntu systemd unit needs to be added |

---

## What We Build on Top

| Addition | Work |
|---|---|
| **Telegram channel** | `src/channels/telegram.ts` using `grammy` |
| **Web channel** | `src/channels/web.ts` — Hono WebSocket + JWT auth |
| **Channel isolation enforcement** | `ChannelContext` type propagated end-to-end; router dispatches back to origin only |
| **Dashboard REST API** | Agent status, subagent list, audit log, task history |
| **Agent soul / identity** | `container/AGENT_SOUL.md` injected into container's CLAUDE.md stack |
| **Confirmation flow** | New MCP tool; agent pauses while web UI waits for approve/reject |
| **Audit log table** | New `audit_log` table in `src/db.ts` |
| **Systemd unit** | Ubuntu service file, auto-restart |
| **Caddy reverse proxy** | Auto-TLS HTTPS for web channel |

---

## Architecture Shift: TMUX → Docker

Our original plan used TMUX to manage subagents. NanoClaw uses Docker containers.
**Docker is strictly better:**

| Dimension | TMUX | Docker (NanoClaw) |
|---|---|---|
| Isolation | Process-level only | Full OS namespace isolation |
| Security | Shared filesystem | Mount allowlist, read-only project root |
| Cleanup | Manual | `--rm` auto-removes on exit |
| Secret leakage | Env vars visible to all | Secrets via stdin, deleted immediately |
| Subagent independence | Shared process | Fully independent container per turn |

**Decision: Adopt Docker isolation, drop TMUX.**

---

## Channel Isolation — Core Design Principle

> **Rule:** A message that arrives on channel X must only ever generate a response on channel X.
> The agent has no knowledge of other channels. Isolation is enforced by the host, not the container.

### The `ChannelContext` Type

Every message in the system carries a channel context from the moment it arrives
until the response is delivered. Nothing in this pipeline can change it mid-flight.

```typescript
// src/types.ts — added to existing types
type ChannelType = 'whatsapp' | 'telegram' | 'web';

interface ChannelContext {
  type: ChannelType;
  id: string;      // WhatsApp: group JID | Telegram: chat_id | Web: ws-session-id
}
```

### How It Flows End-to-End

```
1. INBOUND MESSAGE
   Channel adapter (whatsapp.ts / telegram.ts / web.ts)
   receives raw message → wraps it in:
   { content, sender, channelCtx: { type, id } }
   → pushed to src/index.ts message queue

2. CONTAINER SPAWN
   src/container-runner.ts receives the message + channelCtx
   → writes channelCtx into the container's JSON stdin input
   → stores { taskId → channelCtx } in SQLite tasks table

3. INSIDE CONTAINER (agent-runner + MCP server)
   Agent runs. When it calls send_message MCP tool:
   → MCP server writes IPC file to /workspace/ipc/messages/<id>.json
   → IPC file contains { content } ONLY — no channel info
     (container doesn't know and can't choose the channel)

4. HOST-SIDE IPC WATCHER (src/ipc.ts)
   Reads the IPC message file
   → looks up channelCtx from tasks table by taskId / groupFolder
   → passes { content, channelCtx } to src/router.ts

5. ROUTER (src/router.ts)
   switch (channelCtx.type) {
     case 'whatsapp':  whatsappChannel.send(channelCtx.id, content); break;
     case 'telegram':  telegramChannel.send(channelCtx.id, content); break;
     case 'web':       webChannel.send(channelCtx.id, content);      break;
   }
   → response goes back ONLY to the originating channel
```

### Why the Container Cannot Break Isolation

- The container's `send_message` MCP tool has **no `channel` or `target` parameter**
- The only output path from the container is the IPC file in its isolated `/workspace/ipc/` namespace
- Channel routing decisions live entirely in host-side code (`src/router.ts`)
- A compromised or misbehaving agent cannot route to a different channel — it has no mechanism to do so

### Channel-Isolated Group Folders

Each conversation gets a unique group folder path that encodes the channel:

```
data/groups/
├── whatsapp/
│   └── 123456789@g.us/      ← WhatsApp group JID
│       ├── .claude/          ← session, memory
│       └── workspace/        ← agent's writable files
├── telegram/
│   └── -1001234567890/      ← Telegram chat_id
│       ├── .claude/
│       └── workspace/
└── web/
    └── a1b2c3d4/            ← Web session UUID
        ├── .claude/
        └── workspace/
```

This means sessions, memory, and workspaces are naturally isolated between channels too.
A web conversation never shares context with a Telegram conversation.

---

## Updated Full Architecture

```
┌──────────────────┐  ┌──────────────────┐  ┌──────────────────────┐
│  WhatsApp (phone)│  │  Telegram (app)  │  │  Browser (web UI)    │
│  @agent trigger  │  │  /start or @bot  │  │  HTTPS chat + dash   │
└────────┬─────────┘  └────────┬─────────┘  └──────────┬───────────┘
         │                     │                        │ HTTPS/WSS
         │ Baileys WS          │ grammy polling         │
         │                     │                        │
┌────────▼─────────────────────▼────────────────────────▼───────────┐
│                    VPS — Ubuntu 22.04                              │
│                                                                    │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │               master-AI Node.js Process                     │   │
│  │                                                             │   │
│  │  src/channels/whatsapp.ts  (existing, Baileys)              │   │
│  │  src/channels/telegram.ts  (NEW — grammy)                   │   │
│  │  src/channels/web.ts       (NEW — Hono WS + JWT auth)       │   │
│  │                            ┌── web/auth.ts                  │   │
│  │                            ├── web/routes.ts                │   │
│  │                            └── web/frontend/  (static UI)   │   │
│  │                                                             │   │
│  │  src/index.ts          ← unified message queue              │   │
│  │  src/router.ts         ← channel-aware outbound dispatch    │   │
│  │  src/container-runner  ← Docker lifecycle + channelCtx      │   │
│  │  src/ipc.ts            ← IPC watcher → router (no rerout.)  │   │
│  │  src/db.ts             ← SQLite + audit_log + channelCtx    │   │
│  │  src/task-scheduler    ← scheduled tasks                    │   │
│  │  src/soul.ts           ← identity config loader (NEW)       │   │
│  └──────────────────────────┬──────────────────────────────────┘   │
│                             │ docker run (per conversation turn)   │
│  ┌──────────────────────────▼──────────────────────────────────┐   │
│  │                Docker Container (ephemeral)                  │   │
│  │                                                             │   │
│  │  container/agent-runner/src/index.ts  ← Claude SDK agent   │   │
│  │  container/agent-runner/src/ipc-mcp-stdio.ts               │   │
│  │    tools: send_message, schedule_task, list_tasks,          │   │
│  │           request_user_confirmation  (NEW)                  │   │
│  │                                                             │   │
│  │  Volumes:                                                   │   │
│  │    /workspace/project   ← project root (read-only)          │   │
│  │    /workspace/group     ← data/groups/<channel>/<id>/       │   │
│  │    /workspace/ipc       ← data/ipc/<channel>/<id>/          │   │
│  │    /workspace/.claude   ← sessions/<channel>/<id>/.claude/  │   │
│  │                                                             │   │
│  │  CLAUDE.md stack (auto-loaded):                             │   │
│  │    /workspace/project/CLAUDE.md  ← project context         │   │
│  │    /workspace/.claude/AGENT_SOUL.md  ← soul/identity (NEW) │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                    │
│  Caddy reverse proxy  → HTTPS :443 → Hono :3000                   │
└────────────────────────────────────────────────────────────────────┘
```

---

## File Layout (After Fork + Additions)

```
master-AI/  (fork of nanoclaw)
├── src/
│   ├── index.ts               (modified — unified channel queue)
│   ├── container-runner.ts    (modified — carries channelCtx, soul injection)
│   ├── container-runtime.ts   (unchanged)
│   ├── ipc.ts                 (modified — channel-aware routing)
│   ├── db.ts                  (modified — channelCtx columns, audit_log table)
│   ├── router.ts              (modified — dispatches to correct channel by type)
│   ├── task-scheduler.ts      (unchanged)
│   ├── group-queue.ts         (unchanged)
│   ├── group-folder.ts        (modified — channel-namespaced paths)
│   ├── mount-security.ts      (unchanged)
│   ├── config.ts              (modified — web port, Telegram token, soul path)
│   ├── env.ts                 (modified — WEB_JWT_SECRET, TELEGRAM_BOT_TOKEN)
│   ├── soul.ts                (NEW — identity config loader)
│   ├── types.ts               (modified — ChannelContext, ChannelType)
│   ├── logger.ts              (unchanged)
│   └── channels/
│       ├── whatsapp.ts        (modified — attaches channelCtx: {type:'whatsapp', id:jid})
│       ├── telegram.ts        (NEW — grammy bot, attaches channelCtx: {type:'telegram', id:chatId})
│       └── web.ts             (NEW — Hono server, auth, WS, attaches channelCtx: {type:'web', id:wsSessionId})
│           └── web/
│               ├── auth.ts    (NEW — JWT + bcrypt)
│               ├── routes.ts  (NEW — dashboard, audit log, confirm endpoint)
│               └── frontend/  (NEW — static HTML+JS chat UI)
├── container/
│   ├── Dockerfile             (unchanged)
│   ├── agent-runner/
│   │   └── src/
│   │       ├── index.ts       (unchanged — soul injected via CLAUDE.md, not code)
│   │       └── ipc-mcp-stdio.ts  (modified — add request_user_confirmation tool)
│   ├── skills/
│   │   └── agent-browser/     (unchanged)
│   └── AGENT_SOUL.md          (NEW — agent identity, deferred until named)
├── systemd/
│   └── master-ai.service      (NEW — Ubuntu systemd unit)
├── Caddyfile                  (NEW — reverse proxy config)
├── .env.example               (modified — add WEB_JWT_SECRET, TELEGRAM_BOT_TOKEN)
├── PLAN.md
├── NANOCLAW_ANALYSIS.md
└── CLAUDE.md
```

---

## Telegram Channel — Key Notes

**Library:** [`grammy`](https://grammy.dev) — modern, TypeScript-first Telegram bot framework.

**Trigger pattern (mirrors WhatsApp):**
- Group messages that mention the bot (`@botname`) or reply to the bot
- Direct messages to the bot always trigger the agent

**`chat_id` as group identifier:**
- Telegram `chat_id` is stable for groups (negative integers for groups, positive for DMs)
- Used as the `id` in `ChannelContext` and as the folder name under `data/groups/telegram/`

**Webhook vs polling:**
- Development: long-polling (no public URL needed)
- Production: webhook via HTTPS (Caddy handles TLS, grammy handles webhook route)

**Auth token:**
- `TELEGRAM_BOT_TOKEN` in `.env`
- Passed to container via stdin (same as `ANTHROPIC_API_KEY`), deleted immediately

---

## Web Channel — Key Notes

**Auth flow (single-user):**
```
POST /auth/login  { password: "..." }
→ bcrypt.compare(password, WEB_PASSWORD_HASH from .env)
→ { accessToken (15 min JWT), refreshToken (7 day JWT) }

WS upgrade: GET /ws/chat?token=<accessToken>
→ verify JWT → upgrade to WebSocket → assign wsSessionId
```

**WebSocket message protocol:**
```jsonc
// Browser → Server
{ "type": "user_message", "content": "Do X" }
{ "type": "confirm", "actionId": "abc123", "approved": true }

// Server → Browser
{ "type": "agent_message",          "content": "...", "ts": "..." }
{ "type": "agent_streaming_chunk",  "content": "..." }
{ "type": "tool_call",              "tool": "run_shell", "args": {...} }
{ "type": "confirmation_request",   "actionId": "abc123", "description": "...", "riskLevel": "high" }
{ "type": "subagent_update",        "id": "...", "status": "running" }
{ "type": "task_update",            "taskId": "...", "status": "done" }
```

**Dashboard endpoints (all require JWT):**
```
GET  /api/status        → uptime, active containers, memory stats
GET  /api/subagents     → active Docker containers (agent processes)
GET  /api/tasks         → paginated task history
GET  /api/audit-log     → paginated audit trail
GET  /api/channels      → registered WhatsApp groups, Telegram chats, active WS sessions
```

---

## Confirmation Flow (Cross-Channel)

Confirmation requests always go to the **web UI**, regardless of which channel triggered the action.
Rationale: WhatsApp and Telegram are not suitable for approve/reject UI; the web dashboard is.

```
1. Agent calls request_user_confirmation MCP tool
   → IPC file: data/ipc/<channel>/<id>/confirmations/<actionId>.json
   → host ipc.ts detects it → stores in SQLite pending_confirmations table

2. Web dashboard:
   → polls GET /api/pending-confirmations
   → or receives { type: 'confirmation_request' } via WebSocket push

3. User clicks Approve or Reject in web UI:
   → POST /api/confirm/<actionId>  { approved: true/false }
   → host writes data/ipc/<channel>/<id>/confirmations/<actionId>.result.json

4. Container is watching for the result file (polling inside ipc-mcp-stdio.ts)
   → reads result → returns { approved } to the agent
   → agent continues (or aborts if rejected)
```

---

## SQLite Schema Changes

Changes to `src/db.ts` on top of the existing NanoClaw schema:

```sql
-- Extend messages table: add channel tracking
ALTER TABLE messages ADD COLUMN channel_type TEXT;  -- 'whatsapp'|'telegram'|'web'
ALTER TABLE messages ADD COLUMN channel_id   TEXT;  -- JID | chat_id | ws-session-id

-- Extend registered_groups: add channel type
ALTER TABLE registered_groups ADD COLUMN channel_type TEXT DEFAULT 'whatsapp';

-- Extend sessions: scoped by channel
ALTER TABLE sessions ADD COLUMN channel_type TEXT DEFAULT 'whatsapp';

-- NEW: Audit log (append-only, application enforces no UPDATE/DELETE)
CREATE TABLE IF NOT EXISTS audit_log (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp    TEXT    NOT NULL DEFAULT (datetime('now')),
  channel_type TEXT,           -- 'whatsapp' | 'telegram' | 'web' | 'scheduler'
  channel_id   TEXT,           -- specific chat/session
  actor        TEXT,           -- 'agent' | 'user' | 'scheduler' | 'system'
  action       TEXT NOT NULL,  -- 'container_spawn' | 'tool_call' | 'message_sent' | 'confirmation_requested' | ...
  detail       TEXT,           -- JSON blob
  outcome      TEXT            -- 'success' | 'denied' | 'error' | 'pending'
);

-- NEW: Pending confirmation requests
CREATE TABLE IF NOT EXISTS pending_confirmations (
  action_id    TEXT PRIMARY KEY,
  channel_type TEXT,
  channel_id   TEXT,
  description  TEXT,
  risk_level   TEXT,           -- 'low' | 'medium' | 'high'
  created_at   TEXT NOT NULL DEFAULT (datetime('now')),
  resolved_at  TEXT,
  approved     INTEGER         -- NULL=pending, 1=approved, 0=rejected
);
```

---

## .env.example (Updated)

```bash
# Claude / Anthropic
ANTHROPIC_API_KEY=sk-ant-...

# WhatsApp — no token needed; auth via QR scan (npm run auth)

# Telegram
TELEGRAM_BOT_TOKEN=123456789:AAF...         # from @BotFather
TELEGRAM_WEBHOOK_SECRET=...                 # random string for webhook validation

# Web channel
WEB_PORT=3000
WEB_JWT_SECRET=                             # openssl rand -hex 32
WEB_PASSWORD_HASH=                          # bcryptjs hash of your password

# Agent soul (deferred — leave blank until named)
AGENT_SOUL_PATH=container/AGENT_SOUL.md
```

---

## Implementation Sequence

```
Phase 1   VPS setup (Ubuntu, UFW, Fail2Ban, Docker, masteragent user)
Phase 2   Fork bootstrap (npm install, build, smoke test)
Phase 3   Channel isolation refactor
            ├── Add ChannelContext type to src/types.ts
            ├── Update src/channels/whatsapp.ts to attach channelCtx
            ├── Update src/router.ts for channel dispatch
            ├── Update src/db.ts schema
            └── Update src/group-folder.ts for channel-namespaced paths
Phase 4   Telegram channel (src/channels/telegram.ts — grammy)
Phase 5   Web channel (src/channels/web.ts — Hono + JWT + WS + static UI)
Phase 6   Agent soul injection (deferred until name/soul assigned)
Phase 7   Audit log + confirmation flow
Phase 8   Caddy HTTPS + systemd service
Phase 9   Security hardening (final pass)
Phase 10  Claude Code IDE integration
Phase 11  Testing
```

---

## Remaining Open Item

**Agent soul and name** — document `container/AGENT_SOUL.md` when ready.
Everything else is decided and unblocked.

---

*Last updated: 2026-03-02*

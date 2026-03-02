# NanoClaw Fork Analysis

> **Question:** Can we fork `qwibitai/nanoclaw` and enhance it to become the Master Agent?
> **Verdict:** Yes — strong foundation. ~60% of our plan is already built. Key gap is the web interface.

**Repo:** https://github.com/qwibitai/nanoclaw
**License:** MIT (fork freely, commercial use allowed)
**Activity:** Very high — multiple commits per day, v1.1.6, 17k+ stars, 2.7k forks
**Analyzed:** 2026-03-02

---

## What NanoClaw Already Provides

| Our Plan Requirement | NanoClaw Status | Notes |
|---|---|---|
| Claude SDK agent loop | ✅ Built | `@anthropic-ai/claude-agent-sdk` inside Docker containers |
| Multi-agent / subagents | ✅ Built | `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, MCP-based IPC |
| Persistent session memory | ✅ Built | `sessionId` in SQLite + `CLAUDE_MEMORY.md` per group |
| Task scheduler | ✅ Built | cron / interval / once, SQLite-backed, timezone-aware |
| IPC between host ↔ agent | ✅ Built | Atomic file writes to `/workspace/ipc/`, host-side poller |
| Container-based isolation | ✅ Built | Docker `--rm`, non-root, read-only project mount |
| Secret handling | ✅ Excellent | Secrets passed via stdin only, deleted immediately after read |
| Mount security | ✅ Excellent | External allowlist, hardcoded blocked paths (.ssh, .env, etc.) |
| Per-agent customization | ✅ Built | Per-group agent-runner source copy, recompiled on start |
| Skills engine | ✅ Built | Structured `skills-engine/` for adding features without core changes |
| Audit / logging | ✅ Partial | `pino` structured logging; no dedicated audit trail table yet |
| VPS systemd service | ✅ Partial | macOS launchd plist exists; systemd unit needs to be added |

**What this means:** The hardest parts — container lifecycle, agent loop, multi-agent IPC,
memory, task scheduling, and security boundaries — are **already done and battle-tested**.

---

## What NanoClaw Does NOT Have (Our Additions)

| Our Plan Requirement | NanoClaw Status | Work Needed |
|---|---|---|
| **Web chat interface** | ❌ Missing | Entire new channel: FastAPI + WebSocket + HTML UI |
| **JWT authentication** | ❌ Missing | Auth layer for the web channel |
| **REST API / dashboard** | ❌ Missing | Agent status, subagent list, audit log endpoints |
| **Agent soul / identity** | ❌ Missing | Identity system prompt + persona config |
| **Confirmation flow (UI)** | ❌ Missing | Agent pauses → web UI asks user → resumes |
| **Dedicated audit log** | ❌ Partial | Add `audit_log` table to `src/db.ts` |
| **Systemd unit** | ❌ Missing | Add `systemd/nanoclaw.service` |
| **HTTPS reverse proxy** | ❌ Missing | Caddy config (for web channel) |

---

## Architecture Shift: TMUX → Docker

Our original plan used TMUX to manage subagents. NanoClaw uses Docker containers.
**Docker is strictly better** for this use case:

| Dimension | TMUX approach | Docker approach (NanoClaw) |
|---|---|---|
| Isolation | Process-level only | Full OS-level namespace isolation |
| Security | Shared filesystem | Mount allowlist, read-only project root |
| Cleanup | Manual | `--rm` auto-removes on exit |
| Secret leakage | Env vars visible to all processes | Secrets via stdin, deleted immediately |
| Subagent independence | Shared Python process | Fully independent container per turn |

**Decision: Adopt Docker-based isolation, drop TMUX subagent management.**

---

## Revised Architecture (Fork-based)

```
┌─────────────────────────────────────────────────────────────┐
│                      YOUR BROWSER                           │
│               Web Chat UI + Dashboard                       │
└─────────────────────────┬───────────────────────────────────┘
                          │ HTTPS / WebSocket
┌─────────────────────────▼───────────────────────────────────┐
│                   VPS — Ubuntu 22.04                        │
│                                                             │
│  NEW ┌──────────────────────────────────────────────────┐   │
│      │        Web Channel (FastAPI + Uvicorn)           │   │
│      │  Auth (JWT) → Chat WS → Dashboard API            │   │
│      └──────────────────┬───────────────────────────────┘   │
│                         │                                   │
│  ┌──────────────────────▼───────────────────────────────┐   │
│  │          NanoClaw Core (TypeScript, Node.js)         │   │
│  │                                                      │   │
│  │  src/index.ts         ← message loop orchestrator    │   │
│  │  src/container-runner ← Docker lifecycle             │   │
│  │  src/db.ts            ← SQLite (+ audit_log table)   │   │
│  │  src/task-scheduler   ← cron/interval/once tasks     │   │
│  │  src/ipc.ts           ← host-side IPC file watcher   │   │
│  │                                                      │   │
│  │  NEW: src/channels/web.ts  ← Web channel adapter     │   │
│  │  NEW: src/soul.ts          ← Identity / philosophy   │   │
│  └──────────────────────┬───────────────────────────────┘   │
│                         │ Docker API                        │
│  ┌──────────────────────▼───────────────────────────────┐   │
│  │              Docker Containers (per turn)            │   │
│  │                                                      │   │
│  │  container/agent-runner/  ← Claude SDK agent         │   │
│  │  container/ipc-mcp-stdio  ← MCP: send_msg, tasks     │   │
│  │  container/skills/        ← browser, custom skills   │   │
│  │                                                      │   │
│  │  NEW: identity injected as CLAUDE.md at mount time   │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## What We Build on Top of the Fork

### Addition 1 — Web Channel (`src/channels/web.ts`)

Model it after the existing `src/channels/whatsapp.ts` pattern.

- Exposes an in-process event emitter interface: `send(groupId, message)` and `on('message', handler)`
- FastAPI/Uvicorn process connects to this via a lightweight IPC socket or a shared SQLite message queue
- OR: Run web server **inside** Node.js process using `fastify` or `hono` (keeps it single-process)

**Recommended:** Use `hono` (tiny, TypeScript-native) inside the existing Node.js process.
No separate Python service needed.

```
src/
├── channels/
│   ├── whatsapp.ts    (existing)
│   └── web.ts         (NEW — Hono HTTP + WebSocket server)
└── web/
    ├── auth.ts        (NEW — JWT issuance + validation)
    ├── routes.ts      (NEW — chat WS, dashboard, audit log)
    └── frontend/      (NEW — static HTML/JS chat UI)
```

### Addition 2 — Agent Soul (`src/soul.ts` + `container/AGENT_SOUL.md`)

- `src/soul.ts` — loads the agent's identity config (name, philosophy, ethical constraints)
- At container spawn time, `container-runner.ts` writes `AGENT_SOUL.md` into the group's
  session directory and adds it to `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD`
- The agent reads its own identity as part of its CLAUDE.md stack on every invocation

### Addition 3 — Audit Log Table

Add to `src/db.ts`:
```sql
CREATE TABLE IF NOT EXISTS audit_log (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL DEFAULT (datetime('now')),
  actor TEXT,        -- 'master' | 'subagent' | 'user' | 'scheduler'
  action TEXT,       -- 'tool_call' | 'message_sent' | 'container_spawn' | ...
  detail TEXT,       -- JSON
  outcome TEXT       -- 'success' | 'denied' | 'error'
);
```

### Addition 4 — Confirmation Flow

Add to the MCP server (`container/agent-runner/src/ipc-mcp-stdio.ts`):
- New tool: `request_user_confirmation(action_description, risk_level)`
- Writes a confirmation request to `/workspace/ipc/confirmations/<id>.json`
- Agent loop **blocks** until a corresponding `confirm/<id>.json` appears (host writes it after user approves via web UI)

### Addition 5 — Systemd Unit

```ini
[Unit]
Description=NanoClaw Master Agent
After=docker.service network.target
Requires=docker.service

[Service]
Type=simple
User=masteragent
WorkingDirectory=/opt/master-ai
ExecStart=/usr/bin/node dist/index.js
Restart=on-failure
RestartSec=5
EnvironmentFile=/opt/master-ai/.env

[Install]
WantedBy=multi-user.target
```

---

## Updated Implementation Plan (Fork-based)

### Phase 1 — VPS Foundation *(unchanged from PLAN.md)*
Same Ubuntu hardening, UFW, Fail2Ban, dedicated `masteragent` user.
Add: `apt install docker.io -y` and add `masteragent` to the `docker` group.

### Phase 2 — Fork and Bootstrap

- [ ] Fork `qwibitai/nanoclaw` into `paphavitmooc/master-AI` (or a new repo)
- [ ] Clone to `/opt/master-ai/` on VPS
- [ ] Copy `.env.example` → `.env`, populate secrets:
  - `ANTHROPIC_API_KEY`
  - `WEB_JWT_SECRET` (generate: `openssl rand -hex 32`)
  - `WEB_PASSWORD_HASH` (generate with bcrypt)
- [ ] Run `npm install` and `npm run build`
- [ ] Build the Docker container image: `npm run build:container`
- [ ] Smoke test: `npm run start` — verify agent launches

### Phase 3 — Agent Soul

- [ ] Write `container/AGENT_SOUL.md` — the agent's identity, philosophy, ethical constitution
- [ ] Create `src/soul.ts` — loads soul config, exposes it to `container-runner.ts`
- [ ] Modify `container-runner.ts` to inject `AGENT_SOUL.md` into the container's CLAUDE.md stack
- [ ] Test: start a conversation, verify the agent introduces itself in character

### Phase 4 — Web Channel

- [ ] Install `hono` and `@hono/node-server` into the project
- [ ] Create `src/channels/web.ts` implementing the channel interface
- [ ] Create `src/web/auth.ts` — JWT + bcrypt password auth
- [ ] Create `src/web/routes.ts` — chat WebSocket, dashboard, audit endpoints
- [ ] Build minimal frontend: `src/web/frontend/index.html` (plain HTML + WebSocket JS)
- [ ] Integrate web channel into `src/index.ts` (alongside existing WhatsApp channel)
- [ ] Test: open browser → log in → send a message → receive agent response

### Phase 5 — Audit Log + Confirmation Flow

- [ ] Add `audit_log` table to `src/db.ts`
- [ ] Wrap `container-runner.ts` container spawns with audit log entries
- [ ] Add `request_user_confirmation` tool to MCP server
- [ ] Implement confirmation polling in `src/ipc.ts`
- [ ] Add confirmation request display + approve/reject buttons to web UI

### Phase 6 — HTTPS + Systemd

- [ ] Install Caddy, configure reverse proxy to Hono's port
- [ ] Point DNS A record → VPS IP
- [ ] Create `systemd/master-ai.service`, enable it
- [ ] Verify auto-restart: `sudo systemctl kill master-ai` → confirm it restarts

### Phase 7 — Security Hardening *(same as PLAN.md Phase 7)*

- [ ] Verify mount allowlist is set at `~/.config/nanoclaw/mount-allowlist.json`
- [ ] Audit `.env` permissions (mode 600)
- [ ] Verify Docker container runs as non-root `node` user
- [ ] Add login rate limiting to web auth

### Phase 8 — Claude Code IDE Integration *(same as PLAN.md Phase 8)*

### Phase 9 — Testing

- [ ] Run NanoClaw's existing test suite: `npm test`
- [ ] Add tests for web auth (JWT issuance, expiry, refresh)
- [ ] Add tests for confirmation flow (request → approve → resume)
- [ ] Manual acceptance: end-to-end web chat with a tool-calling action that requires confirmation

---

## Effort Comparison

| Approach | Estimated Build Effort | Risk |
|---|---|---|
| Build from scratch (original PLAN.md) | High — everything from zero | High — untested architecture |
| Fork NanoClaw + add web layer | Medium — web channel + soul layer | Low — proven core |

**Conclusion: Fork NanoClaw.** The container isolation, multi-agent IPC, task scheduling,
and security model are production-quality and would take weeks to build from scratch.
The web channel and soul layer are the real value-adds specific to our use case.

---

## Key Decisions Before Starting Phase 2

1. **Fork into the same repo (`master-AI`) or a new one?**
   - Same repo: simpler, one place to track everything
   - New repo: cleaner separation of "nanoclaw fork" vs "project config"

2. **Web server inside Node.js process (Hono) or separate Python FastAPI?**
   - Hono: single process, one language (TypeScript), no inter-process communication needed
   - FastAPI: our team knows Python better, but adds complexity

3. **Keep WhatsApp channel or remove it?**
   - Keep: allows messaging the agent from phone
   - Remove: simplifies codebase if web UI is sufficient

4. **Agent name and soul document** — write this before any code (it shapes everything)

---

*Last updated: 2026-03-02*
